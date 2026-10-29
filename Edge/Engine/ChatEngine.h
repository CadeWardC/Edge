// Thin C API over llama.cpp for the text-only chat model (Qwen3.5), callable from Swift.
// All functions on one engine must be called from the same serial queue.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Return false from the callback to stop the generation early.
typedef bool (*chat_text_callback)(const char * utf8, void * user_data);

typedef struct chat_engine chat_engine;

chat_engine * chat_engine_create(const char * model_path, int32_t n_ctx, bool use_gpu, char * err, size_t err_len);

void chat_engine_free(chat_engine * engine);

// Formats messages with the model's own chat template and ends with the assistant header.
// Writes up to out_len bytes and returns the full length (call again with a bigger buffer if larger),
// or -1 when the template is not supported. Also reports whether the template uses <think> blocks.
int32_t chat_engine_render(chat_engine * engine,
                               const char **     roles,
                               const char **     contents,
                               int32_t           n_messages,
                               char *            out,
                               int32_t           out_len,
                               bool *            out_uses_think);

// Generation from a fresh context; stops at the model's end-of-turn token. Returns 0 on success.
int32_t chat_engine_generate(chat_engine * engine,
                                 const char *      prompt,
                                 int32_t           max_tokens,
                                 float             temperature,
                                 chat_text_callback on_text,
                                 void *            user_data);

const char * chat_engine_last_error(const chat_engine * engine);

#ifdef __cplusplus
}
#endif
