#!/usr/bin/env python3
"""Run one explicitly selected development voice test and retain its actual report."""
import argparse
import json
import math
from pathlib import Path
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = 'app.capyvibe.phrayo.voiceprobe'


def failures(report, max_first_frame_ms=None, max_underruns=None):
    problems = []
    if report.get('completed') is not True or report.get('error'):
        problems.append(report.get('error') or 'Synthesis did not complete')
    for key, limit in [('first_observed_playback_frame_ms', max_first_frame_ms),
                       ('underruns', max_underruns)]:
        if limit is None:
            continue
        value = report.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
            problems.append(f'{key}: missing or invalid measurement')
        elif value > limit:
            problems.append(f'{key}: {value:.1f} exceeds {limit}')
    return problems


def run():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--language', choices=['en', 'zh', 'yue', 'ja'], default='en')
    parser.add_argument('--variant', choices=['f16', 'q8'], default='f16')
    parser.add_argument('--backend', choices=['cpu', 'vulkan'], default='cpu')
    parser.add_argument('--threads', type=int, choices=range(1, 9), default=4)
    parser.add_argument('--streaming', action='store_true')
    parser.add_argument('--cold', action='store_true')
    parser.add_argument('--save-audio', action='store_true', help='Explicitly retain the generated test sample for listening comparison')
    parser.add_argument('--timeout', type=int, default=300)
    parser.add_argument('--text')
    parser.add_argument('--tokens-file', type=Path)
    parser.add_argument('--cache-slots', type=int, choices=range(11))
    parser.add_argument('--cache-frames', type=int, choices=[512, 1024, 2048], default=1024)
    parser.add_argument('--max-first-frame-ms', type=float)
    parser.add_argument('--max-underruns', type=int)
    args = parser.parse_args()
    fixed_tokens = None
    if args.tokens_file:
        fixed_tokens = json.loads(args.tokens_file.read_text())
        if args.streaming or not isinstance(fixed_tokens, list) or not 1 <= len(fixed_tokens) <= 2048 or any(type(v) is not int or not 0 <= v < 6561 for v in fixed_tokens):
            parser.error('fixed-token tests require 1–2048 valid speech tokens and whole-utterance mode')
    prefix = ['adb', '-s', args.device]
    def adb(*command, check=True):
        return subprocess.run([*prefix, *command], check=check, capture_output=True, text=True, timeout=20)
    run_id = str(uuid.uuid4())
    if args.cold:
        adb('shell', 'am', 'force-stop', PACKAGE)
    command = ['shell', 'am', 'start', '-n', f'{PACKAGE}/.VoiceProbeActivity',
        '--ez', 'run_sample', 'true', '--es', 'language', args.language,
        '--es', 'variant', args.variant, '--es', 'backend', args.backend,
        '--ei', 'threads', str(args.threads), '--es', 'run_id', run_id,
        '--ei', 'cache_slots', str(args.cache_slots if args.cache_slots is not None else int(args.streaming)),
        '--ei', 'cache_frames', str(args.cache_frames),
        '--ez', 'save_audio', str(args.save_audio).lower(),
        '--ez', 'streaming', str(args.streaming).lower()]
    if args.text is not None:
        # adb's shell joins arguments; quote the user-supplied text for that shell.
        import shlex
        command.extend(['--es', 'text', shlex.quote(args.text)])
    if fixed_tokens:
        command.extend(['--es', 'fixed_tokens', ','.join(map(str, fixed_tokens))])
    adb(*command)
    print(f'{run_id}: {args.variant}/{args.backend}, {args.language}, streaming={args.streaming}', flush=True)
    started = time.monotonic()
    try:
        while time.monotonic() - started < args.timeout:
            response = adb('shell', 'cat', f'/sdcard/Android/data/{PACKAGE}/files/reports/latest.json', check=False)
            if response.returncode == 0:
                try:
                    data = json.loads(response.stdout)
                except ValueError:
                    data = {}
                if data.get('run_id') == run_id:
                    output = ROOT / 'build/android-native/reports' / f'{run_id}.json'
                    output.parent.mkdir(parents=True, exist_ok=True)
                    output.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
                    print(json.dumps(data, ensure_ascii=False, indent=2), flush=True)
                    print(f'Report: {output}', flush=True)
                    log = adb('logcat', '-d', '-s', 'PhrayoVoiceProfile:I', '*:S', check=False).stdout
                    begin, end = f'BEGIN {run_id}', f'END {run_id}'
                    lines, collecting = [], False
                    for line in log.splitlines():
                        if begin in line:
                            collecting = True
                        if collecting:
                            lines.append(line)
                        if end in line and collecting:
                            break
                    if lines:
                        output.with_suffix('.profile.log').write_text('\n'.join(lines) + '\n')
                    if data.get('audio_file') == f'{run_id}.wav':
                        destination = output.with_suffix('.wav')
                        adb('pull', f'/sdcard/Android/data/{PACKAGE}/files/reports/{run_id}.wav', str(destination))
                        print(f'Audio: {destination}', flush=True)
                    problems = failures(data, args.max_first_frame_ms, args.max_underruns)
                    for problem in problems:
                        print(f'FAIL: {problem}', flush=True)
                    return 1 if problems else 0
            time.sleep(2)
        print('Timed out; requesting cancellation. No latency success is claimed.', flush=True)
        return 1
    finally:
        if time.monotonic() - started >= args.timeout:
            adb('shell', 'am', 'start', '-n', f'{PACKAGE}/.VoiceProbeActivity', '--ez', 'stop', 'true', check=False)


if __name__ == '__main__':
    raise SystemExit(run())
