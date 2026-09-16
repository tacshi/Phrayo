#include <cosyvoice.h>
#include <cosyvoice-lowlevel.h>
#include <ggml-backend.h>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <memory>
#include <string>

int main(int argc, char** argv) {
  if (argc != 4 && argc != 5) {
    std::fprintf(stderr, "Usage: benchmark_voice MODEL PROFILE OUTPUT [--tokens-only]\n");
    return 2;
  }
  using Clock = std::chrono::steady_clock;
  const auto start = Clock::now();
  cosyvoice_init_backend();
  cosyvoice_context_params_v3_t params{};
  cosyvoice_init_default_context_params(&params.base_params.base_params);
  params.base_params.base_params.seed = 42;
  params.base_params.base_params.n_max_seq = 2048;
  params.base_params.base_params.llm_kv_cache_type = COSYVOICE_KV_CACHE_TYPE_F16;
  params.base_params.base_params.llm_allow_kv_cache_fallback = false;
  params.base_params.n_workers = 1;
  params.dit_kv_cache_type = COSYVOICE_KV_CACHE_TYPE_F16;
  params.dit_kv_cache_length = 1024;
  auto model = cosyvoice_load_from_file_ext(argv[1], &params,
    ggml_backend_init_by_type(GGML_BACKEND_DEVICE_TYPE_CPU, nullptr), 4);
  if (!model) return 1;
  auto voice = cosyvoice_prompt_speech_load_from_file(argv[2]);
  if (!voice) { cosyvoice_free(model); return 1; }
  auto prompt = cosyvoice_prompt_init_from_prompt_speech(model, voice);
  if (argc == 5 && std::string(argv[4]) == "--tokens-only") {
    const auto instruction = std::string(cosyvoice_get_instruction_prefix(model)) + " Speak clearly and naturally in English.";
    cosyvoice_prompt_set(model, prompt, COSYVOICE_INFERENCE_MODE_INSTRUCT, instruction.c_str());
    auto tokens = cosyvoice_tokenization_result_create();
    const auto text = "I'd like to book a table for two tomorrow evening.";
    cosyvoice_tokenize(cosyvoice_get_tokenizer(model), text, tokens, false);
    bool ok = cosyvoice_llm_job(model, cosyvoice_tokenization_result_get_tokens(tokens),
      cosyvoice_tokenization_result_get_n_tokens(tokens), prompt);
    if (ok) {
      std::ofstream file(argv[3]);
      file << '[';
      const auto count = cosyvoice_llm_get_n_accepted_tokens(model);
      auto accepted = cosyvoice_llm_get_accepted_tokens(model);
      for (unsigned i=0; i<count; ++i) { if(i) file << ','; file << accepted[i]; }
      file << "]\n";
      std::printf("Saved %u CPU speech tokens\n", count);
    }
    cosyvoice_tokenization_result_free(tokens);
    cosyvoice_prompt_free(prompt); cosyvoice_prompt_speech_free(voice); cosyvoice_free(model);
    return ok ? 0 : 1;
  }
  auto tts = cosyvoice_tts_context_new(model, prompt);
  cosyvoice_tts_context_set_text_normalization_enabled(tts, false);
  cosyvoice_tts_context_set_split_text_enabled(tts, false);
  const auto loaded = Clock::now();
  cosyvoice_generated_speech result{};
  const auto ok = cosyvoice_tts_instruct(tts,
    "I'd like to book a table for two tomorrow evening.",
    "Speak clearly and naturally in English.", 1.0f, &result);
  if (ok && result.length) {
    const auto rate = cosyvoice_get_sample_rate(model);
    std::ofstream file(argv[3], std::ios::binary);
    auto u32 = [&](uint32_t v) { for (int i=0;i<4;++i) file.put(static_cast<char>(v >> (i*8))); };
    auto u16 = [&](uint16_t v) { file.put(static_cast<char>(v)); file.put(static_cast<char>(v >> 8)); };
    file.write("RIFF",4); u32(36 + result.length * 4); file.write("WAVEfmt ",8);
    u32(16); u16(3); u16(1); u32(rate); u32(rate * 4); u16(4); u16(32);
    file.write("data",4); u32(result.length * 4);
    file.write(reinterpret_cast<char*>(result.data), result.length * 4);
    std::printf("{\"load_ms\":%.3f,\"synthesis_ms\":%.3f,\"audio_seconds\":%.3f}\n",
      std::chrono::duration<double,std::milli>(loaded-start).count(),
      std::chrono::duration<double,std::milli>(Clock::now()-loaded).count(),
      static_cast<double>(result.length)/rate);
  }
  cosyvoice_tts_context_free(tts);
  cosyvoice_prompt_free(prompt);
  cosyvoice_prompt_speech_free(voice);
  cosyvoice_free(model);
  return ok ? 0 : 1;
}
