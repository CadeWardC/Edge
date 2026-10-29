// Thin C API over llama.cpp + libmtmd for LFM3-Audio, callable from Swift.
// All functions on one engine must be called from the same serial queue.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lfm_engine lfm_engine;

// Return false from a callback to stop the generation early.
typedef bool (*lfm_text_callback)(const char * utf8, void * user_data);
typedef bool (*lfm_audio_callback)(const float * samples, int32_t n_samples, int32_t sample_rate, void * user_data);

// Loads the backbone GGUF and the mmproj GGUF (audio encoder, depthformer and codec).
// use_gpu runs the backbone on Metal, mmproj_use_gpu the audio encoder and speech generation.
// On failure returns NULL and writes a message into err.
lfm_engine * lfm_engine_create(const char * model_path,
                               const char * mmproj_path,
                               int32_t      n_ctx,
                               bool         use_gpu,
                               bool         mmproj_use_gpu,
                               char *       err,
                               size_t       err_len);

void lfm_engine_free(lfm_engine * engine);

// Sample rate the audio encoder expects (16 kHz for LFM3-Audio).
int32_t lfm_engine_input_sample_rate(const lfm_engine * engine);

// Text generation from a fresh context. The prompt is fully rendered (special tokens included)
// and may contain one "<__media__>" marker where the mono PCM F32 audio is placed.
// Mode-switch tokens are banned, so the answer stays text. Returns 0 on success.
int32_t lfm_engine_generate(lfm_engine *      engine,
                            const char *      prompt,
                            const float *     audio,
                            size_t            n_audio,
                            int32_t           max_tokens,
                            float             temperature,
                            lfm_text_callback on_text,
                            void *            user_data);

// Speech generation from a fresh context. The prompt is the model's "tts" template, ending in <|audio_start|>.
// PCM F32 mono chunks are streamed to on_audio as they are decoded. Returns 0 on success.
int32_t lfm_engine_speak(lfm_engine *       engine,
                         const char *       tts_prompt,
                         int32_t            max_frames,
                         lfm_audio_callback on_audio,
                         void *             user_data);

// Message of the last failure, empty if none. Valid until the next call on the engine.
const char * lfm_engine_last_error(const lfm_engine * engine);

#ifdef __cplusplus
}
#endif
