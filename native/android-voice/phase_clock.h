#pragma once
#ifdef PHRAYO_PROFILE
#include <chrono>
#include <cstdio>
#ifdef __ANDROID__
#include <android/log.h>
#endif
struct PhrayoPhaseClock {
  using Clock = std::chrono::steady_clock;
  Clock::time_point previous = Clock::now();
  unsigned tokens, reference;
  PhrayoPhaseClock(unsigned tokens, unsigned reference) : tokens(tokens), reference(reference) {}
  void mark(const char* phase, long value = 0) {
    const auto now = Clock::now();
    const auto ms = std::chrono::duration<double, std::milli>(now - previous).count();
    previous = now;
#ifdef __ANDROID__
    __android_log_print(ANDROID_LOG_INFO, "PhrayoVoiceProfile", "%s ms=%.3f tokens=%u reference=%u value=%ld", phase, ms, tokens, reference, value);
#else
    std::fprintf(stderr, "%s ms=%.3f tokens=%u reference=%u value=%ld\n", phase, ms, tokens, reference, value);
#endif
  }
};
#else
struct PhrayoPhaseClock {
  PhrayoPhaseClock(unsigned, unsigned) {}
  void mark(const char*, long = 0) {}
};
#endif
