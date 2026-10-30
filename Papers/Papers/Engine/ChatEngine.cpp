#include "ChatEngine.h"

#if __has_include(<llama/llama.h>)
#include <llama/llama.h>
#else
#include "llama.h"
#endif

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// length of the longest prefix of s that does not end inside a UTF-8 sequence
static size_t utf8_complete_prefix(const std::string & s) {
    const size_t n = s.size();
    for (size_t back = 1; back <= std::min<size_t>(4, n); back++) {
        const unsigned char c = (unsigned char) s[n - back];
        if ((c & 0xC0) == 0x80) {
            continue; // continuation byte, keep looking for the lead byte
        }
        size_t need = 1;
        if      ((c & 0xE0) == 0xC0) need = 2;
        else if ((c & 0xF0) == 0xE0) need = 3;
        else if ((c & 0xF8) == 0xF0) need = 4;
        return back >= need ? n : n - back;
    }
    return n;
}

static int32_t default_threads() {
    const int hw = (int) std::thread::hardware_concurrency();
    return std::max(2, std::min(6, hw - 2));
}

struct chat_engine {
    llama_model *       model = nullptr;
    llama_context *     lctx  = nullptr;
    const llama_vocab * vocab = nullptr;
    std::string path;
    bool    gpu       = false;
    int32_t n_ctx_req = 0;
    int32_t n_ctx     = 0;
    int32_t n_batch   = 512;
    std::string error;
};

// the last error llama.cpp logged, added to our own messages so a failure on the phone says why
static std::mutex  log_mutex;
static std::string last_log_error;

static void log_callback(ggml_log_level level, const char * text, void *) {
    if (level == GGML_LOG_LEVEL_ERROR && text) {
        std::lock_guard<std::mutex> lock(log_mutex);
        last_log_error = text;
        while (!last_log_error.empty() && (last_log_error.back() == '\n' || last_log_error.back() == ' ')) {
            last_log_error.pop_back();
        }
    }
    if (level >= GGML_LOG_LEVEL_WARN && level != GGML_LOG_LEVEL_CONT && text) {
        fputs(text, stderr);
    }
}

static std::string with_log(const std::string & msg) {
    std::lock_guard<std::mutex> lock(log_mutex);
    return last_log_error.empty() ? msg : msg + " " + last_log_error;
}

static void clear_log() {
    std::lock_guard<std::mutex> lock(log_mutex);
    last_log_error.clear();
}

static void unload(chat_engine * e) {
    if (e->lctx)  llama_free(e->lctx);
    if (e->model) llama_model_free(e->model);
    e->lctx  = nullptr;
    e->model = nullptr;
    e->vocab = nullptr;
}

// Loads the model and a context, on the GPU (Metal) or on the CPU only.
static bool load(chat_engine * e, bool use_gpu) {
    unload(e);
    e->gpu = use_gpu;
    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = use_gpu ? 999 : 0;
    e->model = llama_model_load_from_file(e->path.c_str(), mparams);
    if (!e->model) {
        e->error = with_log("Could not load the chat model GGUF.");
        return false;
    }
    e->vocab = llama_model_get_vocab(e->model);

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx           = (uint32_t) e->n_ctx_req;
    cparams.n_batch         = (uint32_t) e->n_batch;
    cparams.n_ubatch        = (uint32_t) e->n_batch;
    cparams.n_threads       = default_threads();
    cparams.n_threads_batch = default_threads();
    cparams.no_perf         = true;
    e->lctx = llama_init_from_model(e->model, cparams);
    if (!e->lctx) {
        e->error = with_log("Could not create the chat model context (out of memory?).");
        return false;
    }
    e->n_ctx = (int32_t) llama_n_ctx(e->lctx);
    return true;
}

extern "C" chat_engine * chat_engine_create(const char * model_path, int32_t n_ctx, bool use_gpu,
                                            char * err, size_t err_len) {
    static std::once_flag backend_once;
    std::call_once(backend_once, [] {
        llama_log_set(log_callback, nullptr);
        llama_backend_init();
    });
    clear_log();

    chat_engine * e = new chat_engine();
    e->path      = model_path;
    e->n_ctx_req = n_ctx;
    if (!load(e, use_gpu)) {
        if (err && err_len) {
            snprintf(err, err_len, "%s", e->error.c_str());
        }
        chat_engine_free(e);
        return nullptr;
    }
    return e;
}

extern "C" void chat_engine_free(chat_engine * e) {
    if (!e) {
        return;
    }
    unload(e);
    delete e;
}

extern "C" const char * chat_engine_last_error(const chat_engine * e) {
    return e ? e->error.c_str() : "";
}

extern "C" int32_t chat_engine_render(chat_engine * e, const char ** roles, const char ** contents,
                                          int32_t n_messages, char * out, int32_t out_len, bool * out_uses_think) {
    if (!e->model) {
        return -1;
    }
    const char * tmpl = llama_model_chat_template(e->model, nullptr);
    if (out_uses_think) {
        *out_uses_think = tmpl && strstr(tmpl, "<think>") != nullptr;
    }
    std::vector<llama_chat_message> msgs((size_t) n_messages);
    for (int32_t i = 0; i < n_messages; i++) {
        msgs[(size_t) i] = { roles[i], contents[i] };
    }
    return llama_chat_apply_template(tmpl, msgs.data(), msgs.size(), true, out, out_len);
}

// Returns 0 on success, 1 on a failure, 2 when the prompt itself could not be evaluated (nothing was streamed yet).
static int32_t generate(chat_engine * e, const char * prompt, int32_t max_tokens,
                        float temperature, chat_text_callback on_text, void * user_data) {
    e->error.clear();
    llama_memory_clear(llama_get_memory(e->lctx), true);

    // add_special lets the vocabulary add its own BOS when it wants one
    const int32_t len = (int32_t) strlen(prompt);
    std::vector<llama_token> toks((size_t) len + 16);
    int32_t n = llama_tokenize(e->vocab, prompt, len, toks.data(), (int32_t) toks.size(), true, true);
    if (n < 0) {
        toks.resize((size_t) -n);
        n = llama_tokenize(e->vocab, prompt, len, toks.data(), (int32_t) toks.size(), true, true);
    }
    if (n <= 0) {
        e->error = "Could not tokenize the prompt.";
        return 1;
    }
    toks.resize((size_t) n);
    if (n + max_tokens > e->n_ctx) {
        e->error = "The conversation is too long for the context window.";
        return 1;
    }

    llama_batch batch = llama_batch_init(e->n_batch, 0, 1);
    int32_t rc = 0;
    for (int32_t start = 0; start < n && rc == 0; start += e->n_batch) {
        const int32_t m = std::min(n - start, e->n_batch);
        for (int32_t i = 0; i < m; i++) {
            batch.token   [i]    = toks[(size_t) (start + i)];
            batch.pos     [i]    = start + i;
            batch.n_seq_id[i]    = 1;
            batch.seq_id  [i][0] = 0;
            batch.logits  [i]    = start + i == n - 1;
        }
        batch.n_tokens = m;
        rc = llama_decode(e->lctx, batch);
    }
    llama_batch_free(batch);
    if (rc != 0) {
        e->error = with_log("Could not evaluate the prompt (llama_decode returned " + std::to_string(rc) + ").");
        return 2;
    }

    llama_sampler * smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(smpl, llama_sampler_init_penalties(llama_vocab_n_tokens(e->vocab), 64, 1.05f, 0.0f, 0.0f));
    if (temperature <= 0.0f) {
        llama_sampler_chain_add(smpl, llama_sampler_init_greedy());
    } else {
        llama_sampler_chain_add(smpl, llama_sampler_init_top_k(20));
        llama_sampler_chain_add(smpl, llama_sampler_init_top_p(0.8f, 1));
        llama_sampler_chain_add(smpl, llama_sampler_init_temp(temperature));
        llama_sampler_chain_add(smpl, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
    }

    std::string pending;
    int32_t ret = 0;
    for (int32_t i = 0; i < max_tokens; i++) {
        llama_token tok = llama_sampler_sample(smpl, e->lctx, -1);
        if (llama_vocab_is_eog(e->vocab, tok)) {
            break;
        }
        char buf[256];
        const int np = llama_token_to_piece(e->vocab, tok, buf, sizeof(buf), 0, false);
        if (np > 0) {
            pending.append(buf, (size_t) np);
        }
        const size_t ready = utf8_complete_prefix(pending);
        if (ready > 0) {
            const std::string piece = pending.substr(0, ready);
            pending.erase(0, ready);
            if (on_text && !on_text(piece.c_str(), user_data)) {
                break;
            }
        }
        llama_batch one = llama_batch_get_one(&tok, 1);
        const int32_t step = llama_decode(e->lctx, one);
        if (step != 0) {
            e->error = with_log("Decoding failed during generation (llama_decode returned " + std::to_string(step) + ").");
            ret = 1;
            break;
        }
    }
    if (ret == 0 && !pending.empty() && on_text) {
        on_text(pending.c_str(), user_data);
    }
    llama_sampler_free(smpl);
    return ret;
}

extern "C" int32_t chat_engine_generate(chat_engine * e, const char * prompt, int32_t max_tokens,
                                        float temperature, chat_text_callback on_text, void * user_data) {
    clear_log();
    if (!e->lctx) {
        e->error = "The chat model is not loaded.";
        return 1;
    }
    int32_t rc = generate(e, prompt, max_tokens, temperature, on_text, user_data);
    if (rc == 2 && e->gpu) {
        // some phones' GPUs can't run every operation of this model: run it on the CPU from now on
        const std::string gpu_error = e->error;
        fprintf(stderr, "chat_engine: %s; switching to the CPU\n", gpu_error.c_str());
        clear_log();
        if (!load(e, false)) {
            e->error = gpu_error + " CPU fallback failed: " + e->error;
            return 1;
        }
        rc = generate(e, prompt, max_tokens, temperature, on_text, user_data);
    }
    return rc == 0 ? 0 : 1;
}

extern "C" bool chat_engine_set_gpu(chat_engine * e, bool use_gpu) {
    if (e->gpu == use_gpu && e->lctx) {
        return true;
    }
    clear_log();
    return load(e, use_gpu);
}

extern "C" bool chat_engine_uses_gpu(const chat_engine * e) {
    return e && e->gpu;
}
