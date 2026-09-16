#include <cosyvoice.h>
#include <cstdio>

int main(int argc, char** argv) {
  if (argc != 2) return 2;
  auto prompt = cosyvoice_prompt_speech_load_from_file(argv[1]);
  if (!prompt) {
    std::perror("Unable to load converted voice profile");
    return 1;
  }
  cosyvoice_prompt_speech_free(prompt);
  std::puts("Converted profile accepted by the pinned CosyVoice C++ loader");
}
