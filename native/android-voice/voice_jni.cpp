#include <jni.h>
#include <cosyvoice.h>
#include <cosyvoice-lowlevel.h>
#include <ggml-backend.h>
#include <android/log.h>
#include <mecab.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
struct Session {
  cosyvoice_context_t model = nullptr;
  cosyvoice_prompt_speech_t voice = nullptr;
  cosyvoice_prompt_t prompt = nullptr;
  cosyvoice_tts_context_t tts = nullptr;
  std::atomic<bool> cancelled{false};
  std::mutex control;
  ~Session() {
    if (tts) cosyvoice_tts_context_free(tts);
    if (prompt) cosyvoice_prompt_free(prompt);
    if (voice) cosyvoice_prompt_speech_free(voice);
    if (model) cosyvoice_free(model);
  }
};

void fail(JNIEnv* env, const char* message) {
  if (!env->ExceptionCheck()) env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), message);
}

std::string path(JNIEnv* env, jstring value) {
  const char* utf = env->GetStringUTFChars(value, nullptr);
  if (!utf) throw std::runtime_error("Unable to read path");
  std::string result(utf);
  env->ReleaseStringUTFChars(value, utf);
  return result;
}

std::string bytes(JNIEnv* env, jbyteArray value) {
  std::string result(env->GetArrayLength(value), '\0');
  env->GetByteArrayRegion(value, 0, result.size(), reinterpret_cast<jbyte*>(result.data()));
  return result;
}

struct Callback {
  JavaVM* vm;
  jobject listener;
  jmethodID on_pcm;
  Session* session;
  bool invalid_audio = false;
};

bool pcm(const float* samples, uint32_t count, void* opaque) {
  auto& callback = *static_cast<Callback*>(opaque);
  if (callback.session->cancelled) return false;
  JNIEnv* env = nullptr;
  bool attached = callback.vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) == JNI_EDETACHED;
  if (attached && callback.vm->AttachCurrentThread(&env, nullptr) != JNI_OK) return false;
  bool ok = true;
  // Copy before returning to upstream; its buffers expire at callback return.
  // Small blocks also bound the Java queue when the upstream sends a whole WAV.
  for (uint32_t offset = 0; offset < count && ok; offset += 4800) {
    if (callback.session->cancelled) { ok = false; break; }
    const auto size = std::min<uint32_t>(4800, count - offset);
    if (!std::all_of(samples + offset, samples + offset + size, [](float v) { return std::isfinite(v); })) {
      callback.invalid_audio = true;
      ok = false;
      break;
    }
    auto array = env->NewFloatArray(size);
    if (!array) { ok = false; break; }
    env->SetFloatArrayRegion(array, 0, size, samples + offset);
    ok = env->CallBooleanMethod(callback.listener, callback.on_pcm, array) == JNI_TRUE;
    env->DeleteLocalRef(array);
    if (env->ExceptionCheck()) { ok = false; break; }
  }
  if (attached) callback.vm->DetachCurrentThread();
  return ok;
}
}

extern "C" JNIEXPORT jlong JNICALL
Java_app_capyvibe_phrayo_voice_NativeVoice_create(JNIEnv* env, jobject, jstring model_path, jstring voice_path,
    jint threads, jboolean gpu, jint cache_slots, jint cache_frames) {
  try {
    static std::once_flag initialized;
    std::call_once(initialized, [] { cosyvoice_init_backend(); });
    auto session = std::make_unique<Session>();
    session->voice = cosyvoice_prompt_speech_load_from_file(path(env, voice_path).c_str());
    if (!session->voice) throw std::runtime_error("Voice profile could not be loaded");
    cosyvoice_context_params_v3_t params{};
    cosyvoice_init_default_context_params(&params.base_params.base_params);
    params.base_params.base_params.seed = 42;
    params.base_params.base_params.n_max_seq = 2048;
    params.base_params.base_params.llm_kv_cache_type = COSYVOICE_KV_CACHE_TYPE_F16;
    params.base_params.base_params.llm_allow_kv_cache_fallback = false;
    params.base_params.n_workers = 1;
    params.dit_kv_cache_type = COSYVOICE_KV_CACHE_TYPE_F16;
    params.dit_allow_kv_cache_fallback = false;
    params.dit_kv_fixed_slots = std::clamp(cache_slots, 0, 10);
    params.dit_kv_cache_length = std::clamp(cache_frames, 512, 2048);
    auto backend = ggml_backend_init_by_type(gpu ? GGML_BACKEND_DEVICE_TYPE_GPU : GGML_BACKEND_DEVICE_TYPE_CPU, nullptr);
    if (gpu && !backend) backend = ggml_backend_init_by_type(GGML_BACKEND_DEVICE_TYPE_IGPU, nullptr);
    if (!backend) throw std::runtime_error("Requested inference backend is unavailable");
    __android_log_print(ANDROID_LOG_INFO, "PhrayoVoiceNative", "Backend: %s, CPU threads: %d", ggml_backend_name(backend), threads);
    session->model = cosyvoice_load_from_file_ext(path(env, model_path).c_str(), &params, backend, std::max(1, threads));
    if (!session->model) throw std::runtime_error("Model could not be loaded");
    session->prompt = cosyvoice_prompt_init_from_prompt_speech(session->model, session->voice);
    if (!session->prompt) throw std::runtime_error("Voice conditioning could not be initialized");
    session->tts = cosyvoice_tts_context_new(session->model, session->prompt);
    if (!session->tts) throw std::runtime_error("Speech session could not be initialized");
    cosyvoice_tts_context_set_text_normalization_enabled(session->tts, false);
    cosyvoice_tts_context_set_split_text_enabled(session->tts, false);
    return reinterpret_cast<jlong>(session.release());
  } catch (const std::exception& error) {
    fail(env, error.what());
    return 0;
  }
}

extern "C" JNIEXPORT jint JNICALL
Java_app_capyvibe_phrayo_voice_NativeVoice_sampleRate(JNIEnv*, jobject, jlong handle) {
  return cosyvoice_get_sample_rate(reinterpret_cast<Session*>(handle)->model);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_app_capyvibe_phrayo_voice_NativeVoice_synthesize(JNIEnv* env, jobject, jlong handle,
    jbyteArray text, jbyteArray instruction, jboolean streaming, jintArray fixed_tokens, jobject listener) {
  auto* session = reinterpret_cast<Session*>(handle);
  if (!session) { fail(env, "No voice session"); return false; }
  // Each newly queued synthesis gets a fresh cancellation state. The Kotlin
  // owner never reuses this handle until the preceding call has returned.
  session->cancelled = false;
  Callback callback{};
  callback.session = session;
  env->GetJavaVM(&callback.vm);
  callback.listener = env->NewGlobalRef(listener);
  auto type = env->GetObjectClass(listener);
  callback.on_pcm = env->GetMethodID(type, "onPcm", "([F)Z");
  env->DeleteLocalRef(type);
  if (!callback.listener || !callback.on_pcm) return false;
  bool ok = false;
  try {
    auto spoken = bytes(env, text);
    auto direction = bytes(env, instruction);
    if (fixed_tokens) {
      const auto count = env->GetArrayLength(fixed_tokens);
      if (streaming || count < 1 || count > 2048) throw std::runtime_error("Invalid fixed-token test");
      std::vector<int> tokens(count);
      env->GetIntArrayRegion(fixed_tokens, 0, count, tokens.data());
      if (!std::all_of(tokens.begin(), tokens.end(), [](int v) { return v >= 0 && v < 6561; }))
        throw std::runtime_error("Speech token outside vocabulary");
      cosyvoice_generated_speech result{};
      ok = cosyvoice_token2wav(session->model, tokens.data(), tokens.size(), 1.0f, session->prompt, &result);
      if (ok) ok = result.length > 0 && pcm(result.data, result.length, &callback);
    } else if (streaming) {
      ok = cosyvoice_tts_instruct_stream(session->tts, spoken.c_str(), direction.c_str(), 1.0f, pcm, &callback);
    } else {
      cosyvoice_generated_speech result{};
      ok = cosyvoice_tts_instruct(session->tts, spoken.c_str(), direction.c_str(), 1.0f, &result);
      if (ok) ok = result.length > 0 && pcm(result.data, result.length, &callback);
    }
    if (callback.invalid_audio) throw std::runtime_error("Synthesis returned invalid audio");
    if (!ok && !session->cancelled && !env->ExceptionCheck()) throw std::runtime_error("Synthesis did not complete");
  } catch (const std::exception& error) {
    fail(env, error.what());
  }
  env->DeleteGlobalRef(callback.listener);
  return ok;
}

extern "C" JNIEXPORT void JNICALL
Java_app_capyvibe_phrayo_voice_NativeVoice_stop(JNIEnv*, jobject, jlong handle) {
  auto* session = reinterpret_cast<Session*>(handle);
  if (!session) return;
  session->cancelled = true;
  std::lock_guard<std::mutex> guard(session->control);
  // Called by a separate control executor, never from the PCM callback.
  cosyvoice_request_stop(session->model);
}

extern "C" JNIEXPORT void JNICALL
Java_app_capyvibe_phrayo_voice_NativeVoice_destroy(JNIEnv*, jobject, jlong handle) {
  delete reinterpret_cast<Session*>(handle);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_app_capyvibe_phrayo_voice_NativeVoice_japanese(JNIEnv* env, jobject, jstring dictionary, jbyteArray text) {
  try {
    auto directory = path(env, dictionary);
    const char* argv[] = {"mecab", "-r", "/dev/null", "-d", directory.c_str()};
    auto tagger = std::unique_ptr<MeCab::Tagger>(MeCab::createTagger(5, const_cast<char**>(argv)));
    if (!tagger) throw std::runtime_error("Japanese dictionary could not be loaded");
    auto input = bytes(env, text);
    const MeCab::Node* node = tagger->parseToNode(input.c_str());
    if (!node) throw std::runtime_error("Japanese reading conversion failed");
    std::string output;
    for (; node; node = node->next) {
      if (node->stat == MECAB_BOS_NODE || node->stat == MECAB_EOS_NODE) continue;
      std::vector<std::string> fields;
      std::string feature(node->feature);
      size_t start = 0;
      for (size_t i = 0; i <= feature.size(); ++i) {
        if (i == feature.size() || feature[i] == ',') {
          fields.emplace_back(feature.substr(start, i - start));
          start = i + 1;
        }
      }
      std::string reading(node->surface, node->length);
      // Same IPADic pronunciation -> reading -> dictionary-form fallback as iOS.
      for (auto index : {8, 7, 6}) {
        if (fields.size() > static_cast<size_t>(index) && !fields[index].empty() && fields[index] != "*") {
          reading = fields[index];
          break;
        }
      }
      if (!output.empty()) output += ' ';
      output += reading;
    }
    auto result = env->NewByteArray(output.size());
    if (result) env->SetByteArrayRegion(result, 0, output.size(), reinterpret_cast<const jbyte*>(output.data()));
    return result;
  } catch (const std::exception& error) {
    fail(env, error.what());
    return nullptr;
  }
}
