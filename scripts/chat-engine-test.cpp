// Runs the app's reply request through ChatEngine on a desktop, to reproduce on-device failures.
// Usage: chat-engine-test model.gguf [gpu 0|1]
#include "../Edge/Engine/ChatEngine.h"

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

static bool print_piece(const char * utf8, void *) {
    fputs(utf8, stdout);
    fflush(stdout);
    return true;
}

int main(int argc, char ** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s model.gguf [gpu 0|1]\n", argv[0]);
        return 2;
    }
    const bool gpu = argc > 2 && atoi(argv[2]) != 0;
    char err[512] = {0};
    chat_engine * e = chat_engine_create(argv[1], 2048, gpu, err, sizeof(err));
    if (!e) {
        fprintf(stderr, "load failed: %s\n", err);
        return 1;
    }

    // TutorPrompts.reply(history: [], learner: "我喜欢排球。", level: .beginner)
    const char * roles[] = {"system", "user", "assistant", "user"};
    const char * contents[] = {
        "You are 小林, a warm, patient Mandarin conversation partner for an English-speaking learner. Answer what the "
        "learner says in natural Mandarin: one or two short sentences, ending with a question that keeps the conversation "
        "going. Write only simplified Chinese characters and Chinese punctuation: no pinyin, no English, no explanations. "
        "Use very simple HSK 1-2 words and short sentences (under 15 characters).",
        "我昨天去商店买了三个苹果",
        "你喜欢吃苹果吗？你还买了什么？",
        "我喜欢排球。",
    };
    std::vector<char> buf(8192);
    bool think = false;
    const int32_t n = chat_engine_render(e, roles, contents, 4, buf.data(), (int32_t) buf.size(), &think);
    if (n <= 0) {
        fprintf(stderr, "render failed: %d\n", n);
        return 1;
    }
    std::string prompt(buf.data(), (size_t) n);
    if (think) {
        prompt += "<think>\n\n</think>\n\n";
    }
    printf("--- prompt (%d bytes, think=%d)\n%s\n--- reply\n", n, think, prompt.c_str());

    for (float temp : {0.3f, 0.0f}) {
        const int32_t rc = chat_engine_generate(e, prompt.c_str(), 96, temp, print_piece, nullptr);
        printf("\n--- temp %.1f rc=%d error='%s'\n", temp, rc, chat_engine_last_error(e));
        if (rc != 0) {
            chat_engine_free(e);
            return 1;
        }
    }
    chat_engine_free(e);
    return 0;
}
