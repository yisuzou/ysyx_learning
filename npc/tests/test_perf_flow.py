"""性能台账的数据来源、追加语义及 perf -> make sta 串联回归。

集成测试在临时目录中用受控工具输出替代长时间仿真/综合，不修改正式性能台账。
真实 Nangate45 映射与 iSTA 分析另由 make sta 端到端实跑验证。
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from unittest import mock

NPC = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("perf_record", NPC / "scripts/perf_record.py")
record = importlib.util.module_from_spec(spec)
spec.loader.exec_module(record)

LEDGER = ("# 台账\n\n| commit | 说明 | 仿真周期数 | 指令数 | IPC | 日期 | 综合频率 | 综合面积(µm²) | 配置 | 证据 |\n"
          "|---|---|---|---|---|---|---|---|---|---|\n"
          "| - | 历史 | 20 | 10 | 0.500 | 10-21 | - | - | old | - |\n\n> 保留表后说明。\n")


class RecordTests(unittest.TestCase):
    def test_table_append_preserves_history_and_following_notes(self):
        fields = ["abc", "说明", "100", "50", "0.500", "2026-10-23", "300..301 MHz", "123.456", "new", "JSON"]
        text, row, added = record.ledger_update(LEDGER, fields)
        self.assertTrue(added)
        self.assertIn("| - | 历史", text)
        self.assertLess(text.index(row), text.index("> 保留"))
        again, _, added = record.ledger_update(text, fields)
        self.assertFalse(added)
        self.assertEqual(again, text)
        fields[2] = "101"
        with self.assertRaisesRegex(RuntimeError, "different metrics"):
            record.ledger_update(text, fields)

    def test_description_does_not_break_markdown(self):
        self.assertEqual(record.cell("条件 A | 条件 B\n后续"), "条件 A &#124; 条件 B 后续")

    def test_incomplete_or_inconsistent_simulation_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "simulation.log"
            for text in ("PERF: inst= 50 cycles= 100 IPC= 0.500",
                         "npc: HIT GOOD TRAP\nMicroBench PASS\nPERF: inst= 50 cycles= 100 IPC= 0.900",
                         "npc: HIT GOOD TRAP\nMicroBench PASS\nnpc: HIT BAD TRAP\nPERF: inst= 50 cycles= 100 IPC= 0.500"):
                path.write_text(text)
                with self.assertRaises(RuntimeError):
                    record.simulation_stats(path)

    def test_old_sta_result_cannot_supply_new_metrics(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.json"
            path.write_text(json.dumps({"schema_version": 1, "source_sha256": {"rtl": "old"}}))
            with mock.patch.object(record.sta, "source_hashes", return_value={"rtl": "new"}):
                with self.assertRaisesRegex(RuntimeError, "stale"):
                    record.sta_result(path)


class PerfIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.npc = self.root / "npc"
        scripts = self.npc / "scripts"
        scripts.mkdir(parents=True)
        for name in ("perf.sh", "perf_record.py"):
            shutil.copy2(NPC / "scripts" / name, scripts / name)
        for name in ("native.mk", "sta.mk"):
            shutil.copy2(NPC / "scripts" / name, scripts / name)
        (self.npc / "Makefile").write_text(
            'NPC_HOME ?= $(CURDIR)\ninclude $(NPC_HOME)/scripts/native.mk\ninclude $(NPC_HOME)/scripts/sta.mk\n')
        # native.mk 包含真实构建规则；本测试的构建命令由受控 make 工具替代。
        (scripts / 'build.mk').touch()
        shutil.copytree(NPC / "scripts/sta", scripts / "sta", ignore=shutil.ignore_patterns("__pycache__"))
        (self.npc / "docs").mkdir()
        self.ledger = self.npc / "docs/perf-log.md"
        self.ledger.write_text(LEDGER)
        (self.npc / ".config").write_text("# CONFIG_RVE is not set\n")
        (self.npc / "vsrc").mkdir()
        (self.npc / "vsrc/top.v").write_text("module top; endmodule\n")
        am = self.root / "abstract-machine/scripts"
        am.mkdir(parents=True)
        (am / "riscv32-npc.mk").touch()
        micro = self.root / "am-kernels/benchmarks/microbench"
        micro.mkdir(parents=True)
        (micro / "Makefile").touch()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.tool("git", """
            import os, sys
            if 'status' in sys.argv:
                print(os.environ.get('MOCK_DIRTY', ''), end='')
            elif 'rev-parse' in sys.argv:
                print('0123456789abcdef0123456789abcdef01234567')
            else:
                sys.exit(2)
        """)
        self.tool("make", """
            import json, os, subprocess, sys
            from pathlib import Path
            with open(os.environ['MAKE_CALLS'], 'a') as output:
                output.write(json.dumps(sys.argv[1:]) + '\\n')
            if 'sta' in sys.argv:
                if os.environ.get('MOCK_STA_FAIL'):
                    sys.exit(7)
                subprocess.run([sys.executable, os.environ['MOCK_STA_SCRIPT']], check=True)
            elif 'mainargs=train' in sys.argv:
                print('MicroBench PASS')
                print('npc: HIT BAD TRAP' if os.environ.get('MOCK_SIM_FAIL') else 'npc: HIT GOOD TRAP')
                print('PERF: inst= 50 cycles= 100 IPC= 0.500')
        """)
        # 模拟 STA 的原始报告及结果，但实际执行生产版 report_summary/面积校验/记录器。
        helper = self.root / "fake_sta.py"
        helper.write_text(textwrap.dedent("""
            import json, os, re, sys
            from pathlib import Path
            npc = Path(os.environ['NPC_HOME'])
            sys.path.insert(0, str(npc / 'scripts/sta'))
            import flow
            flow.STA.mkdir(parents=True, exist_ok=True)
            flow.SYNTH.mkdir(parents=True, exist_ok=True)
            flow.NETLIST.write_text('fixture netlist')
            flow.LIBERTY.write_text('fixture liberty')
            run = flow.STA / 'runs/fixture'
            run.mkdir(parents=True, exist_ok=True)
            (run / 'top.rpt').write_text(
                '| ff:D | core_clock | max | 2.7r | 2.8 | 0 | 0.1 | 358 |\\n'
                '| ff:D | core_clock | min | 0.1r | 0 | 0 | 0.1 | NA |\\n')
            for suffix in ('cap', 'trans'):
                (run / ('top.' + suffix)).write_text('| gate:Z | 0.1r | 0.01r | 0.09r | BUF/Z | R |\\n')
            area = flow.STA / 'netlist_stat.txt'
            area.write_text("Chip area for module top: 123.456\\n")
            mem_arg = re.search(r'STA_MEM_BYTES=([0-9]+)', os.environ.get('MAKEFLAGS', ''))
            mem_bytes = int(mem_arg.group(1)) if mem_arg else 4096
            result = {
                'schema_version': 1, 'source_sha256': flow.source_hashes(),
                'netlist_sha256': flow.digest(flow.NETLIST), 'liberty_sha256': flow.digest(flow.LIBERTY),
                'sdc_sha256': flow.digest(flow.FLOW / 'top.sdc'),
                'fmax_lower_mhz': 1000 / 2.79, 'fmax_upper_mhz': 1000 / 2.78,
                'passing_period_ns': 2.79, 'failing_period_ns': 2.78, 'tolerance_ns': 0.01,
                'cell_area_um2': 123.456, 'area_report': str(area),
                'passing_report': str(run / 'top.rpt'), 'trials': [{'model_issues': []}],
                'hold_met_in_all_trials': True, 'tools': {'yosys': 'fixture', 'ista_git': 'fixture'},
                'profile': {'mem_bytes': mem_bytes, 'synthesis_target_ns': 2.0, 'max_fanout_target': 8}}
            flow.write_json(flow.STA / 'result.json', result)
        """))
        self.env = dict(os.environ, NPC_HOME=str(self.npc), AM_HOME=str(self.root / "abstract-machine"),
                        AM_KERNELS_HOME=str(self.root / "am-kernels"),
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        MAKE_CALLS=str(self.root / "make-calls.jsonl"), MOCK_STA_SCRIPT=str(helper))
        # 测试独立于调用它的外层 make、已有 NPC 配置和用户 shell。
        for key in ("MAKEFLAGS", "MFLAGS", "PERF_ARCH", "PERF_TIMEOUT", "PYTHON", "MOCK_DIRTY",
                    "MOCK_STA_FAIL", "MOCK_SIM_FAIL"):
            self.env.pop(key, None)

    def tool(self, name, code):
        path = self.bin / name
        path.write_text("#!/usr/bin/env python3\n" + textwrap.dedent(code))
        path.chmod(0o755)

    def run_perf(self, **extra):
        return subprocess.run(["bash", str(self.npc / "scripts/perf.sh"), "A | B", "riscv32-npc"],
                              env=dict(self.env, **extra), capture_output=True, text=True, timeout=30)

    def calls(self):
        path = self.root / "make-calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_success_uses_sta_metrics_and_appends_once(self):
        result = self.run_perf()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        text = self.ledger.read_text()
        self.assertIn('A &#124; B | 100 | 50 | 0.500', text)
        self.assertIn('358.423..359.712 MHz | 123.456', text)
        self.assertTrue(any('sta' in call for call in self.calls()))
        evidence = list((self.npc / 'build/perf').glob('*/measurement.json'))
        self.assertEqual(len(evidence), 1)
        self.assertEqual(json.loads(evidence[0].read_text())['simulation']['cycles'], 100)
        again = self.run_perf()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(self.ledger.read_text(), text)

    def test_sta_failure_does_not_append_even_if_old_result_exists(self):
        self.assertEqual(self.run_perf().returncode, 0)
        before = self.ledger.read_text()
        result = self.run_perf(MOCK_STA_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.ledger.read_text(), before)

    def test_make_entry_preserves_sta_overrides_and_literal_description(self):
        sentinel = self.root / 'should-not-exist'
        desc = f'A | B `touch {sentinel}`'
        result = subprocess.run([shutil.which('make'), '-C', str(self.npc), 'perf',
                                 f'DESC={desc}', 'STA_MEM_BYTES=8192'],
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(sentinel.exists())
        self.assertIn('sta_mem=8192B', self.ledger.read_text())
        self.assertIn(f'A &#124; B `touch {sentinel}`', self.ledger.read_text())

    def test_repeated_measurement_restores_cleaned_evidence_without_new_row(self):
        self.assertEqual(self.run_perf().returncode, 0)
        before = self.ledger.read_text()
        shutil.rmtree(self.npc / 'build/perf')
        repeated = self.run_perf()
        self.assertEqual(repeated.returncode, 0, repeated.stderr)
        self.assertEqual(self.ledger.read_text(), before)
        self.assertEqual(len(list((self.npc / 'build/perf').glob('*/measurement.json'))), 1)

    def test_bad_simulation_does_not_start_sta_or_append(self):
        result = self.run_perf(MOCK_SIM_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any('sta' in call for call in self.calls()))
        self.assertEqual(self.ledger.read_text(), LEDGER)

    def test_dirty_sources_are_refused_before_build(self):
        result = self.run_perf(MOCK_DIRTY=' M npc/vsrc/top.v\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.ledger.read_text(), LEDGER)


if __name__ == '__main__':
    unittest.main()
