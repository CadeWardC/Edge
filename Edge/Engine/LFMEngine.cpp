#include "LFMEngine.h"

#if __has_include(<llama/llama.h>)
#include <llama/llama.h>
#include <llama/mtmd.h>
#include <llama/mtmd-helper.h>
#else
#include "llama.h"
#include "mtmd.h"
#include "mtmd-helper.h"
#endif

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

struct lfm_engine {
    llama_model *           model = nullptr;
    llama_context *         lctx  = nullptr;
    mtmd_context *          mctx  = nullptr;
    mtmd_helper_gen_audio * gen   = nullptr;
    const llama_vocab *     vocab = nullptr;

    int32_t n_ctx   = 0;
    int32_t n_batch = 512;

    llama_token tok_im_end = LLAMA_TOKEN_NULL;
    // tokens that would switch the response to speech, banned while generating text
    std::vector<llama_logit_bias> text_only_bias;

    std::string error;
};

static void set_error(lfm_engine * e, const std::string & msg) {
    e->error = msg;
    fprintf(stderr, "lfm_engine: %s\n", msg.c_str());
}

static llama_token find_special_token(const llama_vocab * vocab, const char * piece) {
    llama_token toks[4];
    const int n = llama_tokenize(vocab, piece, (int32_t) strlen(piece), toks, 4, false, true);
    return n == 1 ? toks[0] : LLAMA_TOKEN_NULL;
}

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

extern "C" lfm_engine * lfm_engine_create(const char * model_path, const char * mmproj_path, int32_t n_ctx,
                                          bool use_gpu, bool mmproj_use_gpu, char * err, size_t err_len) {
    static std::once_flag backend_once;
    std::call_once(backend_once, [] { llama_backend_init(); });

    auto fail = [&](lfm_engine * e, const char * msg) -> lfm_engine * {
        if (err && err_len) {
            snprintf(err, err_len, "%s", msg);
        }
        lfm_engine_free(e);
        return nullptr;
    };

    lfm_engine * e = new lfm_engine();

    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = use_gpu ? 999 : 0;
    e->model = llama_model_load_from_file(model_path, mparams);
    if (!e->model) {
        return fail(e, "Could not load the model GGUF.");
    }
    e->vocab = llama_model_get_vocab(e->model);

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx           = (uint32_t) n_ctx;
    cparams.n_batch         = (uint32_t) e->n_batch;
    cparams.n_ubatch        = (uint32_t) e->n_batch;
    cparams.n_threads       = default_threads();
    cparams.n_threads_batch = default_threads();
    cparams.embeddings      = true; // speech generation reads the backbone hidden states
    cparams.no_perf         = true;
    e->lctx = llama_init_from_model(e->model, cparams);
    if (!e->lctx) {
        return fail(e, "Could not create the llama context (out of memory?).");
    }
    e->n_ctx = (int32_t) llama_n_ctx(e->lctx);

    mtmd_context_params mtparams = mtmd_context_params_default();
    mtparams.use_gpu       = mmproj_use_gpu;
    mtparams.n_threads     = default_threads();
    mtparams.print_timings = false;
    e->mctx = mtmd_init_from_file(mmproj_path, e->model, mtparams);
    if (!e->mctx) {
        return fail(e, "Could not load the mmproj GGUF.");
    }
    if (!mtmd_support_audio(e->mctx)) {
        return fail(e, "This mmproj has no audio encoder. Use the LFM3-Audio mmproj.");
    }
    if (mtmd_gen_audio_get_info(e->mctx).type != MTMD_GEN_AUDIO_TYPE_LFM3A) {
        return fail(e, "This mmproj cannot generate LFM3-Audio speech.");
    }

    e->gen = mtmd_helper_gen_audio_init(e->lctx, e->mctx);
    if (!e->gen) {
        return fail(e, "Could not initialize speech generation.");
    }

    e->tok_im_end = find_special_token(e->vocab, "<|im_end|>");
    for (const char * piece : { "<|audio_start|>", "<|mixed_start|>" }) {
        const llama_token t = find_special_token(e->vocab, piece);
        if (t != LLAMA_TOKEN_NULL) {
            e->text_only_bias.push_back({ t, -INFINITY });
        }
    }
    return e;
}

extern "C" void lfm_engine_free(lfm_engine * e) {
    if (!e) {
        return;
    }
    if (e->gen)   mtmd_helper_gen_audio_free(e->gen);
    if (e->mctx)  mtmd_free(e->mctx);
    if (e->lctx)  llama_free(e->lctx);
    if (e->model) llama_model_free(e->model);
    delete e;
}

extern "C" int32_t lfm_engine_input_sample_rate(const lfm_engine * e) {
    const int sr = e && e->mctx ? mtmd_get_audio_sample_rate(e->mctx) : 0;
    return sr > 0 ? sr : 16000;
}

extern "C" const char * lfm_engine_last_error(const lfm_engine * e) {
    return e ? e->error.c_str() : "";
}

extern "C" int32_t lfm_engine_generate(lfm_engine * e, const char * prompt, const float * audio, size_t n_audio,
                                       int32_t max_tokens, float temperature, lfm_text_callback on_text, void * user_data) {
    e->error.clear();
    llama_memory_clear(llama_get_memory(e->lctx), true);

    mtmd_input_text text;
    text.text          = prompt;
    text.text_len      = strlen(prompt);
    text.add_special   = false; // the prompt carries its own <|startoftext|>
    text.parse_special = true;

    mtmd::bitmap_ptr bitmap;
    std::vector<const mtmd_bitmap *> bitmaps;
    if (audio && n_audio > 0) {
        bitmap.reset(mtmd_bitmap_init_from_audio(n_audio, audio));
        if (!bitmap) {
            set_error(e, "Could not wrap the recording.");
            return 1;
        }
        bitmaps.push_back(bitmap.get());
    }

    mtmd::input_chunks_ptr chunks(mtmd_input_chunks_init());
    if (mtmd_tokenize(e->mctx, chunks.get(), &text, bitmaps.data(), bitmaps.size()) != 0) {
        set_error(e, "Could not tokenize the prompt.");
        return 1;
    }
    if ((int32_t) mtmd_helper_get_n_tokens(chunks.get()) + max_tokens > e->n_ctx) {
        set_error(e, "The conversation is too long for the context window.");
        return 1;
    }

    llama_pos n_past = 0;
    if (mtmd_helper_eval_chunks(e->mctx, e->lctx, chunks.get(), 0, 0, e->n_batch, true, &n_past) != 0) {
        set_error(e, "Could not evaluate the prompt.");
        return 1;
    }

    llama_sampler * smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    const int32_t n_vocab = llama_vocab_n_tokens(e->vocab);
    if (!e->text_only_bias.empty()) {
        llama_sampler_chain_add(smpl, llama_sampler_init_logit_bias(n_vocab, (int32_t) e->text_only_bias.size(),
                                                                    e->text_only_bias.data()));
    }
    llama_sampler_chain_add(smpl, llama_sampler_init_penalties(n_vocab, 64, 1.05f, 0.0f, 0.0f));
    if (temperature <= 0.0f) {
        llama_sampler_chain_add(smpl, llama_sampler_init_greedy());
    } else {
        llama_sampler_chain_add(smpl, llama_sampler_init_top_k(40));
        llama_sampler_chain_add(smpl, llama_sampler_init_top_p(0.9f, 1));
        llama_sampler_chain_add(smpl, llama_sampler_init_temp(temperature));
        llama_sampler_chain_add(smpl, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
    }

    std::string pending;
    int32_t ret = 0;
    for (int32_t i = 0; i < max_tokens; i++) {
        llama_token tok = llama_sampler_sample(smpl, e->lctx, -1);
        if (llama_vocab_is_eog(e->vocab, tok) || tok == e->tok_im_end) {
            break;
        }

        char buf[256];
        const int n = llama_token_to_piece(e->vocab, tok, buf, sizeof(buf), 0, false);
        if (n > 0) {
            pending.append(buf, (size_t) n);
            const size_t ready = utf8_complete_prefix(pending);
            if (ready > 0) {
                const std::string out = pending.substr(0, ready);
                pending.erase(0, ready);
                if (on_text && !on_text(out.c_str(), user_data)) {
                    break;
                }
            }
        }

        llama_batch batch = llama_batch_get_one(&tok, 1);
        if (llama_decode(e->lctx, batch) != 0) {
            set_error(e, "Decoding failed during generation.");
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

extern "C" int32_t lfm_engine_speak(lfm_engine * e, const char * tts_prompt, int32_t max_frames,
                                    lfm_audio_callback on_audio, void * user_data) {
    e->error.clear();
    llama_memory_clear(llama_get_memory(e->lctx), true);

    mtmd_helper_gen_audio_inp inp = mtmd_helper_gen_audio_inp_default();
    inp.stream     = true;
    inp.seq_id     = 0;
    inp.prompt     = tts_prompt;
    inp.prompt_len = strlen(tts_prompt);
    inp.out_type   = MTMD_HELPER_GEN_AUDIO_OUTTYPE_PCM;
    if (mtmd_helper_gen_audio_set_input(e->gen, &inp) != 0) {
        set_error(e, "Could not start speech generation.");
        return 1;
    }

    for (;;) {
        const int32_t left = mtmd_helper_gen_audio_step_prompt(e->gen, e->n_batch);
        if (left < 0) {
            set_error(e, "Speech prompt evaluation failed.");
            return 1;
        }
        if (left == 0) {
            break;
        }
    }

    // forwards whatever PCM the codec has produced since the last call
    bool keep_going = true;
    auto drain = [&]() -> bool {
        int32_t sample_rate = 0;
        const char * data = nullptr;
        size_t len = 0;
        if (mtmd_helper_gen_audio_get_output(e->gen, &sample_rate, &data, &len, nullptr) != 0) {
            set_error(e, "Could not read generated audio.");
            return false;
        }
        if (len > 0 && on_audio && keep_going) {
            keep_going = on_audio((const float *) data, (int32_t) (len / sizeof(float)), sample_rate, user_data);
        }
        return true;
    };

    // LFM3-Audio speaks from the hidden state; a text token is only sampled when the pipeline asks for one
    llama_sampler * greedy = llama_sampler_init_greedy();
    auto next_token = [&]() -> llama_token {
        if (!mtmd_helper_gen_audio_next_is_text(e->gen)) {
            return LLAMA_TOKEN_NULL;
        }
        return llama_sampler_sample(greedy, e->lctx, -1);
    };

    int32_t ret = 0;
    const float * h_state = llama_get_embeddings_ith(e->lctx, -1);
    llama_token sampled = next_token();
    for (int32_t frame = 0; frame < max_frames && keep_going; frame++) {
        const float * h_next = nullptr;
        bool stop = false;
        if (mtmd_helper_gen_audio_step_gen(e->gen, sampled, h_state, &h_next, &stop) != 0) {
            set_error(e, "Speech generation failed.");
            ret = 1;
            break;
        }
        if (!drain()) {
            ret = 1;
            break;
        }
        if (stop || !h_next) {
            break;
        }
        h_state = h_next;
        sampled = next_token();
    }
    llama_sampler_free(greedy);

    if (ret == 0) {
        if (mtmd_helper_gen_audio_flush(e->gen) != 0 || !drain()) {
            set_error(e, "Could not flush generated audio.");
            ret = 1;
        }
    }
    return ret;
}
