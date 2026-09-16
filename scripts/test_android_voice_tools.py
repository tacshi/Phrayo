"""Validation of benchmark acceptance, independent of device availability."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('voice_probe', Path(__file__).with_name('run-android-voice-probe.py'))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class BenchmarkAcceptanceTest(unittest.TestCase):
    def test_completed_audio_does_not_bypass_latency_and_underrun_limits(self):
        report = dict(completed=True, first_observed_playback_frame_ms=38767.4, underruns=8)
        self.assertEqual(len(probe.failures(report, 15000, 0)), 2)

    def test_missing_nonfinite_or_negative_measurements_fail_closed(self):
        for value in [None, float('nan'), float('inf'), -1, True, '100']:
            with self.subTest(value=value):
                report = dict(completed=True, first_observed_playback_frame_ms=value, underruns=0)
                self.assertTrue(probe.failures(report, 15000, 0))

    def test_valid_boundary_and_unconstrained_reports(self):
        report = dict(completed=True, first_observed_playback_frame_ms=15000, underruns=0)
        self.assertFalse(probe.failures(report, 15000, 0))
        self.assertFalse(probe.failures(dict(completed=True)))

    def test_runtime_failure_never_passes_on_fast_timing(self):
        report = dict(completed=False, error='No audio focus', first_observed_playback_frame_ms=1, underruns=0)
        self.assertEqual(probe.failures(report, 15000, 0), ['No audio focus'])


if __name__ == '__main__':
    unittest.main()
