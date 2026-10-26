"""报告配对、引脚连接、转义数组名和输入身份的关键路径追踪回归。"""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "sta_trace", Path(__file__).resolve().parents[1] / "scripts/sta/trace_paths.py")
trace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trace)


class StaTraceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.raw = self.root / "mapped.v"
        self.sta = self.root / "sta.v"
        self.source_map = self.root / "mapped.json"
        self.report = self.root / "top.rpt"
        self.output = self.root / "trace"
        self.raw.write_text(
            "module top;\n"
            "  DFFR_X1 _start_ (\n    .CK(clk),\n    .D(_old_),\n"
            "    .Q(\\ifu1.inst [20]),\n    .RN(rst_n)\n  );\n"
            "  MUX2_X1 _mux_ (\n    .A(1'h0),\n    .B(1'h1),\n"
            "    .S(\\ifu1.inst [20]),\n    .Z(_data_)\n  );\n"
            "  DFFR_X1 _end_ (\n    .CK(clk),\n    .D(_data_),\n"
            "    .Q(\\wbu1.gpr1.rf[11] [31]),\n    .RN(rst_n)\n  );\nendmodule\n")
        self.sta.write_text(self.raw.read_text().replace("\\ifu1.inst [20]", "debug_inst_20_")
                            .replace("\\wbu1.gpr1.rf[11] [31]", "rf_11_31_"))
        modules = {
            "DFFR_X1": {"ports": {pin: {"direction": direction} for pin, direction in
                (("CK", "input"), ("D", "input"), ("Q", "output"), ("RN", "input"))}},
            "MUX2_X1": {"ports": {pin: {"direction": "output" if pin == "Z" else "input"}
                                     for pin in ("A", "B", "S", "Z")}},
            "top": {"cells": {}, "netnames": {
                "ifu1.inst": {"attributes": {"src": "vsrc/IFU.v:3.1-3.9"}},
                "wbu1.gpr1.rf[11]": {"attributes": {"src": "vsrc/GPR.v:2.1-2.9"}}}}}
        self.source_map.write_text(json.dumps({"modules": modules}))
        (self.root / "vsrc").mkdir()
        for name in ("IFU", "GPR"):
            (self.root / f"vsrc/{name}.v").write_text("// source\n// declaration\n// other\n")
        self.metadata = {"netlist_sha256": trace.digest(self.sta), "profile": {
            "mapped_netlist_sha256": trace.digest(self.raw), "source_map_sha256": trace.digest(self.source_map)},
            "source_sha256": {f"vsrc/{name}.v": trace.digest(self.root / f"vsrc/{name}.v")
                              for name in ("IFU", "GPR")}}
        summaries = ("| _end_:D | core_clock | max | 0.300f | 0.200 | 0 | -0.100 | 1 |\n"
                     "| _end_:D | core_clock | min | 0.300r | 0.100 | 0 | 0.200 | NA |\n")
        self.report.write_text(summaries + self.detail("setup", -0.1) + self.detail("hold", 0.2))

    @staticmethod
    def row(point, incr="", arrival="", fanout=""):
        return "| " + " | ".join((point, fanout, "0.001", "0.000", "0.010", "", incr, arrival)) + " |\n"

    def detail(self, kind, slack):
        row = self.row
        return ("| Point | Fanout | Capacitance | Resistance | Transition | Delta Delay | Incr | Path |\n"
                + row("_start_:CK (DFFR_X1)", "0", "0")
                + row("clock core_clock (rise edge)", "0", "0")
                + row("_start_:CK (DFFR_X1)", "0", "0")
                + row("_start_:Q (DFFR_X1)", "0.100", "0.100f")
                + row("debug_inst_20_ (net)", fanout="1")
                + row("_mux_:S (MUX2_X1)", "0", "0.100f")
                + row("_mux_:Z (MUX2_X1)", "0.200", "0.300f")
                + row("_data_ (net)", fanout="1")
                + row("_end_:D (DFFR_X1)", "0", "0.300f")
                + row("")
                + row("_end_:CK (DFFR_X1)", "99", "99")
                + row(f"library {kind} time", "-0.041", "99")
                + row("slack (MET)", "", str(slack)))

    def generate(self, **kwargs):
        return trace.generate(self.metadata, self.report, self.raw, self.sta,
                              self.source_map, self.output, root=self.root, **kwargs)

    def test_signal_distinguishes_escaped_array_name_from_bit_select(self):
        self.assertEqual(trace.signal(r"\wbu1.gpr1.rf[11] [31]"), ("wbu1.gpr1.rf[11]", 31))
        self.assertEqual(trace.display(r"\wbu1.gpr1.rf[11] [31]"), "wbu1.gpr1.rf[11][31]")

    def test_trace_maps_registers_and_counts_cell_arcs_not_clock_rows(self):
        path = self.generate()["paths"][0]
        self.assertEqual(path["startpoint"]["q_signal"], "ifu1.inst[20]")
        self.assertEqual(path["endpoint"]["q_signal"], "wbu1.gpr1.rf[11][31]")
        self.assertEqual(path["combinational_stages"], 1)
        self.assertAlmostEqual(path["clock_to_q_ns"], 0.1)
        self.assertAlmostEqual(path["combinational_delay_ns"], 0.2)
        self.assertTrue(path["stages"][1]["mux_select"])
        self.assertEqual(path["stages"][1]["connections"]["A"], "1'h0")
        self.assertTrue(path["startpoint"]["rtl_declarations"][0]["verified"])
        self.assertIn("wbu1.gpr1.rf[11][31]", self.output.with_suffix(".md").read_text())

    def test_same_endpoint_setup_and_hold_remain_separate(self):
        paths = self.generate(kind="all")["paths"]
        self.assertEqual([path["kind"] for path in paths], ["setup", "hold"])
        self.assertEqual(self.generate(kind="hold")["paths"][0]["slack_ns"], 0.2)

    def test_setup_paths_sorted_by_slack_and_keep_tied_endpoints(self):
        self.report.write_text(
            "| _end_:D | core_clock | max | 0.300f | 0.200 | 0 | -0.100 | 1 |\n"
            "| _end_:D | core_clock | max | 0.300r | 0.100 | 0 | -0.200 | 1 |\n"
            + self.detail("setup", -0.1) + self.detail("setup", -0.2))
        paths = self.generate(limit=1)["paths"]
        self.assertEqual(len(paths), 1)
        self.assertEqual(paths[0]["slack_ns"], -0.2)

    def test_mismatched_sta_netlist_is_rejected_before_output(self):
        self.sta.write_text(self.sta.read_text() + "// different generation\n")
        with self.assertRaisesRegex(ValueError, "does not match"):
            self.generate()
        self.assertFalse(self.output.with_suffix(".json").exists())

    def test_mismatched_source_map_is_rejected(self):
        self.source_map.write_text(self.source_map.read_text() + "\n")
        with self.assertRaisesRegex(ValueError, "source_map_sha256 mismatch"):
            self.generate()

    def test_broken_connection_is_not_presented_as_a_path(self):
        self.raw.write_text(self.raw.read_text().replace(".S(\\ifu1.inst [20])", ".S(other_net)"))
        self.metadata["profile"]["mapped_netlist_sha256"] = trace.digest(self.raw)
        with self.assertRaisesRegex(ValueError, "disconnected mapped path"):
            self.generate()
        self.assertFalse(self.output.with_suffix(".md").exists())

    def test_changed_rtl_is_not_linked_as_verified_source(self):
        (self.root / "vsrc/IFU.v").write_text("// changed source\n")
        path = self.generate()["paths"][0]
        self.assertFalse(path["startpoint"]["rtl_declarations"][0]["verified"])
        self.assertIn("源码身份未验证", self.output.with_suffix(".md").read_text())

    def test_truncated_detail_table_is_rejected(self):
        self.report.write_text(self.report.read_text().rsplit("slack (MET)", 1)[0])
        with self.assertRaisesRegex(ValueError, "does not match"):
            self.generate()

    def test_legacy_metadata_is_explicit_about_missing_hashes(self):
        del self.metadata["profile"]
        self.assertEqual(len(self.generate()["notes"]), 2)


if __name__ == "__main__":
    unittest.main()
