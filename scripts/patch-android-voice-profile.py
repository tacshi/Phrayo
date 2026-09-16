#!/usr/bin/env python3
"""Apply optional stage timers to the pinned native source."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'build/android-native/cosyvoice.cpp-1616b12215407193fafb08111e7fd2939f977789/src'


def patch(file, replacements):
    path = SOURCE / file
    text = path.read_text()
    for before, after in replacements:
        if after in text:
            continue
        if text.count(before) != 1:
            raise RuntimeError(f'{file}: profile patch does not match pinned source')
        text = text.replace(before, after)
    path.write_text(text)


def main():
    patch('cosyvoice-token2wav.cpp', [
        ('#include "ggml-cpu-flag.h"', '#include "ggml-cpu-flag.h"\n#include "phase_clock.h"'),
        ('    use_count_guard _guard(this);',
         '    use_count_guard _guard(this);\n    PhrayoPhaseClock profile(n_tokens, prompt->flow_prompt_speech_tokens.second);'),
        ('    worker->status = ggml_backend_sched_graph_compute(sched.get(), gf);\n    shared->noise_callback(COSYVOICE_NOISE_CALLBACK_STAGE_AFTER_FLOW',
         '    profile.mark("flow_prepare", seq_len);\n    worker->status = ggml_backend_sched_graph_compute(sched.get(), gf);\n    profile.mark("flow_first_step", seq_len);\n    shared->noise_callback(COSYVOICE_NOISE_CALLBACK_STAGE_AFTER_FLOW'),
        ('        worker->status = ggml_backend_sched_graph_compute(sched.get(), gf);',
         '        profile.mark("flow_step_prepare", step);\n        worker->status = ggml_backend_sched_graph_compute(sched.get(), gf);\n        profile.mark("flow_step_compute", step);'),
        ('    // Phase 3: Copy flow output to speech_feat (persistent buffer)',
         '    profile.mark("flow_finish", seq_len);\n    // Phase 3: Copy flow output to speech_feat (persistent buffer)'),
        ('    worker->status = ggml_backend_sched_graph_compute(sched.get(), gf);\n    shared->noise_callback(COSYVOICE_NOISE_CALLBACK_STAGE_AFTER_HIFT',
         '    profile.mark("hift_prepare", generated_speech->ne[0]);\n    worker->status = ggml_backend_sched_graph_compute(sched.get(), gf);\n    profile.mark("hift_compute", generated_speech->ne[0]);\n    shared->noise_callback(COSYVOICE_NOISE_CALLBACK_STAGE_AFTER_HIFT'),
    ])
    patch('cosyvoice.cpp', [
        ('#include "cosyvoice-internal.h"', '#include "cosyvoice-internal.h"\n#include "phase_clock.h"'),
        ('    if (ctx->llm_job(text, text_len, prompt)\n        && ctx->token2wav',
         '    PhrayoPhaseClock profile(text_len, prompt->flow_prompt_speech_tokens.second);\n    const bool llm_ok = ctx->llm_job(text, text_len, prompt);\n    profile.mark("llm", ctx->llm_get_n_accepted_tokens());\n    if (llm_ok\n        && ctx->token2wav'),
        ('            if (!final)\n                if (!ctx->llm_job_ext(text, text_len, prompt, chunk_tokens + 1, &final))\n                    goto cleanup;',
         '            if (!final) {\n                PhrayoPhaseClock profile(text_len, prompt->flow_prompt_speech_tokens.second);\n                if (!ctx->llm_job_ext(text, text_len, prompt, chunk_tokens + 1, &final))\n                    goto cleanup;\n                profile.mark("llm_chunk", ctx->llm_get_n_accepted_tokens());\n            }'),
    ])


if __name__ == '__main__':
    main()
