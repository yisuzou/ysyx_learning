"""Check that STA report failures cannot become passing Fmax results."""
import argparse
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location(
    "sta_flow", Path(__file__).resolve().parents[1] / "scripts/sta/flow.py")
flow = importlib.util.module_from_spec(spec)
spec.loader.exec_module(flow)


class StaFlowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)

    def make_report(self, setup=-0.2, hold=0.1, arrival=0.1, cap=0.01, slew=0.01):
        (self.directory / "top.rpt").write_text(
            f"| endpoint:D | core_clock | max | 2.2r | 2 | 0 | {setup} | 450 |\n"
            f"| endpoint:D | core_clock | min | {arrival}r | 0 | 0 | {hold} | NA |\n")
        for suffix, slack in (("cap", cap), ("trans", slew)):
            (self.directory / f"top.{suffix}").write_text(
                f"| gate:Z | 0.061r/0.061f | 0.01r/0.01f | {slack}r/{slack}f | BUF_X1/Z | R |\n")

    def test_setup_failure_is_independent_of_hold(self):
        self.make_report()
        result = flow.report_summary(self.directory)
        self.assertFalse(result["setup_met"])
        self.assertTrue(result["hold_met"])
        self.assertEqual(result["model_issues"], [])

    def test_rounded_zero_is_not_accepted_as_passing_margin(self):
        self.make_report(setup=-0.000)
        self.assertFalse(flow.report_summary(self.directory)["setup_met"])

    def test_extrapolation_and_electrical_violations_are_reported(self):
        self.make_report(arrival=-1861, cap=-32.354, slew=-309.352)
        result = flow.report_summary(self.directory)
        self.assertEqual(len(result["model_issues"]), 3)

    def test_empty_path_report_is_rejected(self):
        self.make_report()
        (self.directory / "top.rpt").write_text("No constrained paths\n")
        with self.assertRaisesRegex(RuntimeError, "missing constrained"):
            flow.report_summary(self.directory)

    def test_empty_electrical_report_is_rejected(self):
        self.make_report(setup=0.1)
        (self.directory / "top.cap").write_text("No capacitance checks\n")
        with self.assertRaisesRegex(RuntimeError, "missing electrical checks"):
            flow.report_summary(self.directory)

    def search(self, analyze):
        args = argparse.Namespace(start_ns=2.0, tolerance_ns=0.01, ieda="unused")
        with mock.patch.object(flow, "STA", self.directory), \
                mock.patch.object(flow, "digest", return_value="fixed"), \
                mock.patch.object(flow, "analyze", side_effect=analyze), \
                contextlib.redirect_stdout(io.StringIO()):
            flow.bisect_period(args)

    def test_bisection_brackets_known_boundary(self):
        def analyze(period, _):
            return {"setup_met": period >= 5.25, "hold_met": True,
                    "model_issues": [], "period_ns": period}
        self.search(analyze)
        result = json.loads((self.directory / "fmax.json").read_text())
        self.assertLess(result["failing_period_ns"], 5.25)
        self.assertGreaterEqual(result["passing_period_ns"], 5.25)
        self.assertLessEqual(result["passing_period_ns"] - result["failing_period_ns"], 0.01)

    def test_bad_electrical_model_stops_search(self):
        def analyze(period, _):
            return {"setup_met": True, "hold_met": True,
                    "model_issues": ["cap violation"]}
        with self.assertRaisesRegex(RuntimeError, "model checks failed"):
            self.search(analyze)
        self.assertFalse((self.directory / "fmax.json").exists())

    def test_input_change_during_analysis_stops_search(self):
        state = {"changed": False}

        def analyze(period, _):
            state["changed"] = True
            return {"setup_met": True, "hold_met": True, "model_issues": []}

        args = argparse.Namespace(start_ns=2.0, tolerance_ns=0.01, ieda="unused")
        with mock.patch.object(flow, "STA", self.directory), \
                mock.patch.object(flow, "digest", side_effect=lambda _: str(state["changed"])), \
                mock.patch.object(flow, "analyze", side_effect=analyze):
            with self.assertRaisesRegex(RuntimeError, "changed during analysis"):
                flow.bisect_period(args)
        self.assertFalse((self.directory / "fmax.json").exists())

    def test_area_uses_full_precision_total(self):
        path = self.directory / "stat.txt"
        path.write_text("127327 3.13E+05 cells\nChip area for module '\\top': 313062.848000\n")
        self.assertEqual(flow.area_from_report(path), 313062.848)

    def test_missing_or_invalid_area_is_rejected(self):
        path = self.directory / "stat.txt"
        for text in ("no area", "Chip area for module top: nan", "Chip area for module top: -1"):
            path.write_text(text)
            with self.assertRaises((RuntimeError, ValueError)):
                flow.area_from_report(path)

    def test_failed_full_run_unpublishes_old_result(self):
        path = self.directory / "result.json"
        path.write_text('{"old": true}')
        args = argparse.Namespace(ieda="unused")
        with mock.patch.object(flow, "STA", self.directory), \
                mock.patch.object(flow.shutil, "which", return_value="unused"), \
                mock.patch.object(flow, "source_hashes", return_value={}), \
                mock.patch.object(flow, "synthesize", side_effect=RuntimeError("synth failed")):
            with self.assertRaisesRegex(RuntimeError, "synth failed"):
                flow.complete_flow(args)
        self.assertFalse(path.exists())

    def test_rtl_change_during_full_run_prevents_publication(self):
        args = argparse.Namespace(ieda="unused")
        with mock.patch.object(flow, "STA", self.directory), \
                mock.patch.object(flow.shutil, "which", return_value="unused"), \
                mock.patch.object(flow, "source_hashes", side_effect=[{"rtl": "old"}, {"rtl": "new"}]), \
                mock.patch.object(flow, "synthesize"), \
                mock.patch.object(flow, "bisect_period", return_value={}):
            with self.assertRaisesRegex(RuntimeError, "changed during make sta"):
                flow.complete_flow(args)
        self.assertFalse((self.directory / "result.json").exists())


if __name__ == "__main__":
    unittest.main()
