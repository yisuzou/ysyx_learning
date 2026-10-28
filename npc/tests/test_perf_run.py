"""Exercise make sim -> NPC -> CSV -> real matplotlib PNG in an isolated tree."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

NPC = Path(__file__).resolve().parents[1]
PLOT_PYTHON = NPC / ".venv-perf/bin/python"


class PerfRunTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="npc-perf-run-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.npc = self.root / "npc"
        scripts = self.npc / "scripts"
        scripts.mkdir(parents=True)
        for name in ("native.mk", "run_perf.py", "plot_perf.py"):
            shutil.copy2(NPC / "scripts" / name, scripts / name)
        (scripts / "build.mk").write_text(
            'BUILD_DIR = $(NPC_HOME)/build\nBINARY = $(NPC_HOME)/fake-npc\n')
        (self.npc / "Makefile").write_text(
            f'NPC_HOME := {self.npc}\nPYTHON := {sys.executable}\n'
            'CONFIG_BATCH_MODE := y\ninclude $(NPC_HOME)/scripts/native.mk\n')
        self.executable(self.npc / "fake-npc", """
            import argparse, csv, sys
            from pathlib import Path
            parser = argparse.ArgumentParser()
            parser.add_argument('--perf-trace')
            parser.add_argument('--log')
            parser.add_argument('-b', action='store_true')
            parser.add_argument('--status', type=int, default=0)
            parser.add_argument('--bad-csv', action='store_true')
            parser.add_argument('image')
            args = parser.parse_args()
            if args.perf_trace:
                with Path(args.perf_trace).open('w', newline='') as output:
                    writer = csv.writer(output)
                    writer.writerow(['cycle', 'commit', 'fetched', 'prepare', 'ar_wait', 'r_wait', 'lsu_wait'])
                    writer.writerows([[cycle, cycle, cycle, 0, 0, 0, 0] for cycle in range(5)])
                    if args.bad_csv:
                        output.write('7,7,7,0,0,0,0\\n')
            sys.exit(args.status)
        """)
        # Exercise native.mk's default npc/.venv-perf/bin/python lookup without
        # copying an environment or relying on the caller having activated one.
        self.executable(self.npc / ".venv-perf/bin/python",
                        f"import os, sys\nos.execv({str(PLOT_PYTHON)!r}, "
                        f"[{str(PLOT_PYTHON)!r}, *sys.argv[1:]])\n")
        self.csv = self.npc / "build/perf/sample-riscv32e-npc.csv"
        self.env = dict(os.environ, MPLCONFIGDIR=str(self.root / "mpl-cache"))

    def executable(self, path, source):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"#!{sys.executable}\n" + textwrap.dedent(source))
        path.chmod(0o755)

    def make(self, *options):
        return subprocess.run(["make", "-s", "-C", str(self.npc), "sim",
                               "IMG=/unrelated/tests/build/sample-riscv32e-npc.bin",
                               "CONFIG_PERF_TRACE=y", *options], cwd=self.root,
                              env=self.env, capture_output=True, text=True, timeout=30)

    def assert_png(self, path):
        self.assertTrue(path.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"))

    def test_default_make_creates_csv_and_png_under_npc_build(self):
        result = self.make()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.csv.is_file())
        self.assert_png(self.csv.with_suffix(".png"))
        self.assertIn("5 samples, cycles 0..4", result.stdout)

    def test_custom_file_and_preview_range(self):
        custom = self.root / "output with spaces/custom.csv"
        result = self.make(f"PERF_TRACE_FILE={custom}", "PERF_PLOT_END=2")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.csv.exists())
        self.assert_png(custom.with_suffix(".png"))
        self.assertIn("3 samples, cycles 0..2", result.stdout)

    def test_last_explicit_cli_path_is_used_for_both_outputs(self):
        custom = self.root / "explicit path/result.csv"
        result = self.make(f"ARGS=-b --perf-trace=unused.csv --perf-trace '{custom}'")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.csv.exists())
        self.assertFalse((self.npc / "unused.csv").exists())
        self.assert_png(custom.with_suffix(".png"))

    def test_guest_failure_is_preserved_after_plotting(self):
        result = self.make("ARGS=-b --status=7")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Error 7", result.stderr)
        self.assert_png(self.csv.with_suffix(".png"))

    def test_help_does_not_plot_an_old_trace(self):
        self.csv.parent.mkdir(parents=True)
        self.csv.write_text("old trace\n")
        self.csv.with_suffix(".png").write_bytes(b"old picture")
        result = self.make("ARGS=--help")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.csv.read_text(), "old trace\n")
        self.assertEqual(self.csv.with_suffix(".png").read_bytes(), b"old picture")

    def test_missing_plot_python_keeps_csv_and_reports_failure(self):
        self.csv.parent.mkdir(parents=True)
        self.csv.with_suffix(".png").write_bytes(b"old picture")
        result = self.make(f"PERF_PLOT_PYTHON={self.root}/missing-python")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CSV saved, but plotting", result.stderr)
        self.assertTrue(self.csv.is_file())
        self.assertFalse(self.csv.with_suffix(".png").exists())

    def test_plot_failure_cannot_turn_a_bad_guest_into_success(self):
        result = self.make("ARGS=-b --status=7 --bad-csv")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("consecutive", result.stderr)
        self.assertIn("Error 7", result.stderr)

    def test_disabled_trace_does_not_need_python_environment(self):
        result = self.make("CONFIG_PERF_TRACE=", f"PERF_PLOT_PYTHON={self.root}/missing-python")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.csv.exists())

    def test_real_clean_removes_artifacts_and_preserves_environment(self):
        self.csv.parent.mkdir(parents=True)
        self.csv.write_text("generated trace\n")
        result = subprocess.run(["make", "-s", "-f", str(NPC / "scripts/build.mk"),
                                 "clean", f"NPC_HOME={self.npc}"], cwd=self.npc,
                                env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.npc / "build").exists())
        self.assertTrue((self.npc / ".venv-perf/bin/python").is_file())


if __name__ == "__main__":
    unittest.main()
