"""llm-cost 单测套件(unittest, 零第三方依赖)。"""
import json
import sys
import tempfile
import unittest
from decimal import Decimal
from pathlib import Path
from unittest.mock import patch

SCRIPTS_DIR = Path(__file__).resolve().parents[1] / "skills" / "llm-cost" / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import llm_cost  # noqa: E402


def _prices_with_test_model() -> dict:
    """注入 hit≠miss 的测试模型(分档拆分可观测), 其余取真实注册表值。"""
    p = llm_cost.load_prices()
    p["models"]["test-model"] = {
        "hit": Decimal("0.1"), "miss": Decimal("1.0"), "out": Decimal("1.0"),
        "currency": "CNY",
    }
    return p


class TestKernel(unittest.TestCase):
    def test_flash_1m_in_05m_out(self):
        # 1M×0.28 + 0.5M×2.84 = 0.28 + 1.42 = 1.70 (spec 判据①)
        self.assertEqual(
            llm_cost.cost_from_tokens("deepseek-v4-flash", 1_000_000, 500_000),
            Decimal("1.70"))

    def test_cache_hit_same_price_flash(self):
        # flash 预置 hit=miss 同价 → 400k hit 与全 miss 同值 1.70 (spec 判据②)
        self.assertEqual(
            llm_cost.cost_from_tokens("deepseek-v4-flash", 1_000_000, 500_000,
                                      cache_hit_tokens=400_000),
            Decimal("1.70"))

    def test_tier_split_injected_model(self):
        # hit=0.1/miss=1.0/out=1.0: 400k×0.1 + 600k×1.0 + 500k×1.0 = 0.04+0.6+0.5
        self.assertEqual(
            llm_cost.cost_from_tokens("test-model", 1_000_000, 500_000,
                                      cache_hit_tokens=400_000,
                                      prices=_prices_with_test_model()),
            Decimal("1.14"))

    def test_anthropic_convention(self):
        # input 不含 cache_read: hit=400k, miss=input=600k → 0.04+0.6+0.5 (C1 对拍)
        self.assertEqual(
            llm_cost.cost_from_tokens("test-model", 600_000, 500_000,
                                      cache_hit_tokens=400_000,
                                      hit_included_in_input=False,
                                      prices=_prices_with_test_model()),
            Decimal("1.14"))

    def test_hit_clamped_to_input(self):
        # 默认口径防御: cache_hit > input 时钳到 input, miss=0
        self.assertEqual(
            llm_cost.cost_from_tokens("test-model", 5_000, 0,
                                      cache_hit_tokens=195_000,
                                      prices=_prices_with_test_model()),
            Decimal("0.0005"))  # 5k×0.1/1M


class TestNormalizeModel(unittest.TestCase):
    def test_alias_chat_and_reasoner_resolve_flash(self):
        p = llm_cost.load_prices()
        self.assertEqual(llm_cost.normalize_model("deepseek-chat", p),
                         "deepseek-v4-flash")
        self.assertEqual(llm_cost.normalize_model("deepseek-reasoner", p),
                         "deepseek-v4-flash")

    def test_unknown_model_raises(self):
        with self.assertRaises(llm_cost.UnknownModelError):
            llm_cost.normalize_model("gpt-x", llm_cost.load_prices())


class TestLoadPrices(unittest.TestCase):
    def test_bundled_registry_loads(self):
        p = llm_cost.load_prices()
        self.assertEqual(p["models"]["deepseek-v4-flash"]["out"], Decimal("2.84"))
        self.assertEqual(p["models"]["deepseek-v4-pro"]["out"], Decimal("8.52"))

    def test_local_prices_override(self):
        local = {"models": {"deepseek-v4-flash": {
            "hit": 0.28, "miss": 0.28, "out": 9.99, "currency": "CNY"}}}
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            cfg_dir = home / ".claude" / "llm-cost"
            cfg_dir.mkdir(parents=True)
            (cfg_dir / "prices.json").write_text(
                json.dumps(local), encoding="utf-8")
            with patch.object(Path, "home", return_value=home):
                p = llm_cost.load_prices()
        # 本地同键赢(整个模型条目), 未覆盖键继承仓内
        self.assertEqual(p["models"]["deepseek-v4-flash"]["out"], Decimal("9.99"))
        self.assertEqual(p["models"]["deepseek-v4-pro"]["out"], Decimal("8.52"))
        # 本地未动 aliases 继承
        self.assertEqual(p["aliases"]["deepseek-chat"], "deepseek-v4-flash")


class TestFileSource(unittest.TestCase):
    def _tmp_file(self, content: str, suffix: str) -> Path:
        import tempfile
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        p = Path(td.name) / f"usage{suffix}"
        p.write_text(content, encoding="utf-8")
        return p

    def test_jsonl_three_rows(self):
        # 行1 带 cache_hit(flash 同价=1.70) / 行2 未知模型(跳过) / 行3 普通(0.056)
        lines = [
            '{"model": "deepseek-v4-flash", "input_tokens": 1000000, "output_tokens": 500000, "cache_hit_tokens": 400000}',
            '{"model": "gpt-x", "input_tokens": 100, "output_tokens": 100}',
            '{"model": "deepseek-v4-flash", "input_tokens": 200000, "output_tokens": 0}',
        ]
        path = self._tmp_file("\n".join(lines), ".jsonl")
        rows = llm_cost.parse_file_rows(str(path))
        self.assertEqual(len(rows), 3)
        agg = llm_cost.aggregate_rows(rows, llm_cost.load_prices())
        self.assertEqual(agg["total"], Decimal("1.756"))
        self.assertEqual(agg["skipped_unknown_models"], 1)
        self.assertEqual(agg["unknown_models"], ["gpt-x"])

    def test_csv_column_override(self):
        csv_text = ("prompt_tokens,completion_tokens,model\n"
                    "1000000,500000,deepseek-v4-flash\n")
        path = self._tmp_file(csv_text, ".csv")
        rows = llm_cost.parse_file_rows(
            str(path), col_map={"input_tokens": "prompt_tokens",
                                "output_tokens": "completion_tokens"})
        agg = llm_cost.aggregate_rows(rows, llm_cost.load_prices())
        self.assertEqual(agg["total"], Decimal("1.70"))

    def test_format_sniff_csv(self):
        csv_text = ("input_tokens,output_tokens,model\n"
                    "200000,0,deepseek-v4-flash\n")
        path = self._tmp_file(csv_text, ".csv")  # 不传 fmt → 按扩展名走 csv
        rows = llm_cost.parse_file_rows(str(path))
        agg = llm_cost.aggregate_rows(rows, llm_cost.load_prices())
        self.assertEqual(agg["total"], Decimal("0.056"))

    def test_anthropic_rows_via_flag(self):
        # input 不含 cache_read 的行 + 口径开关 → 1.14 对拍(C1)
        rows = [{"model": "test-model", "input_tokens": 600_000,
                 "output_tokens": 500_000, "cache_hit_tokens": 400_000}]
        agg = llm_cost.aggregate_rows(rows, _prices_with_test_model(),
                                      hit_included_in_input=False)
        self.assertEqual(agg["total"], Decimal("1.14"))

    def test_cost_passthrough_row(self):
        rows = [{"model": None, "cost": Decimal("2.50"), "currency": "CNY"}]
        agg = llm_cost.aggregate_rows(rows, llm_cost.load_prices())
        self.assertEqual(agg["total"], Decimal("2.50"))
        self.assertEqual(agg["skipped_unknown_models"], 0)


class TestSqlConfigChain(unittest.TestCase):
    def test_placeholder_boundaries(self):
        from datetime import date
        today = date(2026, 11, 10)
        start, end = llm_cost.date_window(7, today)
        self.assertEqual((start, end), (date(2026, 11, 4), date(2026, 11, 11)))
        q = llm_cost.substitute_placeholders(
            "SELECT ... WHERE d >= {start_date} AND d < {end_date} LIMIT {days}", 7, today)
        self.assertEqual(q, "SELECT ... WHERE d >= 2026-11-04 AND d < 2026-11-11 LIMIT 7")

    def test_literal_braces_preserved(self):
        from datetime import date
        today = date(2026, 11, 10)
        q = llm_cost.substitute_placeholders(
            "SELECT JSON_EXTRACT(c, '$.a') FROM t WHERE x = '{\"a\":1}' AND {unknown_var} AND {days}",
            3, today)
        # 仅三 token 被换, '{"a":1}' 与 {unknown_var} 原样(I7)
        self.assertIn("'{\"a\":1}'", q)
        self.assertIn("{unknown_var}", q)
        self.assertNotIn("{start_date}", q)
        self.assertTrue(q.endswith("AND 3"))

    def test_transform_cost_passthrough(self):
        raw = [{"d": "2026-11-10", "amt": "12.34"}]
        rows = llm_cost.transform_sql_rows(
            raw, {"day": "d", "cost": "amt"}, "prod")
        self.assertEqual(rows[0]["cost"], "12.34")
        self.assertEqual(rows[0]["source"], "prod")
        self.assertEqual(rows[0]["day"], "2026-11-10")

    def test_transform_model_path(self):
        raw = [{"d": "2026-11-10", "m": "deepseek-v4-flash",
                "ti": "1000000", "to": "500000", "src": "quote"}]
        rows = llm_cost.transform_sql_rows(
            raw, {"day": "d", "model": "m", "input_tokens": "ti",
                  "output_tokens": "to", "source": "src"}, "prod")
        self.assertEqual(rows[0]["model"], "deepseek-v4-flash")
        self.assertEqual(rows[0]["source"], "prod:quote")

    def test_transform_missing_both_raises(self):
        raw = [{"d": "2026-11-10", "ti": "100"}]
        with self.assertRaises(llm_cost.SourceConfigError):
            llm_cost.transform_sql_rows(raw, {"day": "d", "input_tokens": "ti"}, "prod")

    def test_password_env_priority(self):
        import os
        with patch.dict(os.environ, {"MY_DB_PW": "from-env"}):
            self.assertEqual(
                llm_cost.resolve_secret({"password": "plain", "password_env": "MY_DB_PW"}),
                "from-env")
        self.assertEqual(
            llm_cost.resolve_secret({"password": "plain"}), "plain")
        self.assertIsNone(llm_cost.resolve_secret({}))

    def test_load_config_missing_returns_empty(self):
        with tempfile.TemporaryDirectory() as td:
            with patch.object(Path, "home", return_value=Path(td)):
                self.assertEqual(llm_cost.load_config(), {})


class TestRunSqlSource(unittest.TestCase):
    CFG = {"driver": "mysql", "host": "h", "port": 3306, "user": "u",
           "database": "db", "query": "SELECT {days}",
           "column_map": {"day": "d", "cost": "amt"}}

    def _run(self, cfg, connect_exc=None, execute_exc=None, rows=None):
        import sys as _sys
        import types
        from datetime import date
        from unittest import mock
        pymysql = mock.MagicMock()
        mod = types.ModuleType("pymysql")
        mod.connect = pymysql.connect
        mod.cursors = mock.MagicMock()
        conn = pymysql.connect.return_value          # 实现直接持有 conn, 不用 with
        cursor = conn.cursor.return_value.__enter__.return_value
        if connect_exc:
            pymysql.connect.side_effect = connect_exc
        if execute_exc:
            cursor.execute.side_effect = execute_exc
        if rows is not None:
            cursor.fetchall.return_value = rows
        with mock.patch.dict(_sys.modules, {"pymysql": mod}):
            out = llm_cost.run_sql_source("s", cfg, 7, date(2026, 11, 10))
        return out, pymysql

    def test_run_sql_success(self):
        rows = [{"d": "2026-11-10", "amt": "12.34"}]
        (result, reason), pymysql = self._run(self.CFG, rows=rows)
        self.assertIsNone(reason)
        self.assertEqual(result[0]["cost"], "12.34")
        self.assertEqual(result[0]["source"], "s")
        pymysql.connect.assert_called_once()
        # 超时参数随连接传入(I8)
        kwargs = pymysql.connect.call_args.kwargs
        self.assertEqual(kwargs.get("connect_timeout"), 5)
        self.assertEqual(kwargs.get("read_timeout"), 10)

    def test_run_sql_timeout_reason(self):
        out, _ = self._run(self.CFG, connect_exc=Exception("(2013, 'timed out')"))
        self.assertEqual(out, (None, "timeout"))

    def test_run_sql_unreachable_and_auth(self):
        out, _ = self._run(self.CFG, connect_exc=Exception("(2003, 'no route')"))
        self.assertEqual(out, (None, "unreachable"))
        out, _ = self._run(self.CFG, connect_exc=Exception("(1045, 'Access denied')"))
        self.assertEqual(out, (None, "auth_failed"))

    def test_run_sql_query_failed(self):
        out, _ = self._run(self.CFG, execute_exc=Exception("bad sql"))
        self.assertEqual(out, (None, "query_failed"))

    def test_run_sql_config_error_reason(self):
        cfg = dict(self.CFG, column_map={"day": "d"})  # 既无 model 组也无 cost
        out, _ = self._run(cfg, rows=[{"d": "2026-11-10"}])
        self.assertEqual(out, (None, "not_configured"))

    def test_run_sql_missing_driver_or_host(self):
        out, _ = self._run({"query": "SELECT 1"}, rows=[])
        self.assertEqual(out, (None, "not_configured"))


class TestFetchBalance(unittest.TestCase):
    def test_balance_no_key_none(self):
        self.assertIsNone(llm_cost.fetch_balance({}))
        self.assertIsNone(llm_cost.fetch_balance({"base_url": "https://x"}))

    def test_balance_mock_200(self):
        import io
        from unittest.mock import patch
        payload = {"is_available": True, "balance_infos": [
            {"currency": "CNY", "total_balance": "88.50"}]}
        resp = __import__("unittest.mock", fromlist=["MagicMock"]).MagicMock()
        resp.__enter__.return_value.read.return_value = json.dumps(payload).encode()
        with patch("urllib.request.urlopen", return_value=resp) as ur:
            out = llm_cost.fetch_balance(
                {"base_url": "https://api.deepseek.com", "api_key": "sk-x"})
        self.assertEqual(out["is_available"], True)
        self.assertEqual(out["total_balance"], {"CNY": 88.50})
        self.assertIn("checked_at", out)
        req = ur.call_args[0][0]
        self.assertTrue(str(req.full_url).endswith("/user/balance"))
        self.assertEqual(req.headers.get("Authorization"), "Bearer sk-x")

    def test_balance_failure_none(self):
        from unittest.mock import patch
        with patch("urllib.request.urlopen", side_effect=OSError("boom")):
            self.assertIsNone(llm_cost.fetch_balance(
                {"base_url": "https://x", "api_key": "sk-x"}))


class TestCli(unittest.TestCase):
    def _main(self, argv):
        import io
        from contextlib import redirect_stdout
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = llm_cost.main(argv)
        return code, buf.getvalue()

    def test_calc_exit0(self):
        code, out = self._main(["calc", "--model", "deepseek-v4-flash",
                                "--input", "1000000", "--output", "500000"])
        self.assertEqual(code, 0)
        self.assertIn("1.7000", out)  # spec 判据①: 展示 4 位小数

    def test_calc_unknown_model_exit1(self):
        code, out = self._main(["calc", "--model", "gpt-x",
                                "--input", "10", "--output", "10"])
        self.assertEqual(code, 1)
        self.assertIn("未知模型", out)

    def test_file_missing_exit1(self):
        code, out = self._main(["file", "Z:/nope/missing.jsonl"])
        self.assertEqual(code, 1)

    def test_file_with_unknown_row_exit0(self):
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "u.jsonl"
            p.write_text('{"model": "gpt-x", "input_tokens": 1, "output_tokens": 1}\n',
                         encoding="utf-8")
            code, out = self._main(["file", str(p)])
        self.assertEqual(code, 0)                     # 聚合中未知模型→跳过不失败(C2)
        self.assertIn("skipped_unknown_models", out)
        self.assertIn("gpt-x", out)

    def test_argparse_usage_error_exit1(self):
        self.assertEqual(self._main(["calc"])[0], 1)      # 缺必填参数
        self.assertEqual(self._main([])[0], 1)            # 无子命令

    def test_piped_gbk_console_never_crashes(self):
        # Windows GBK 管道下 ¥(U+00A5) 不可编码——脚本经管道跑(Claude/CI)不得崩
        import subprocess
        import sys as _sys
        r = subprocess.run(
            [_sys.executable, str(SCRIPTS_DIR / "llm_cost.py"), "calc",
             "--model", "deepseek-v4-flash", "--input", "1000000",
             "--output", "500000"],
            capture_output=True)
        self.assertEqual(r.returncode, 0)
        self.assertIn("1.7000", r.stdout.decode("utf-8", "replace"))

    def _cfg_with_sources(self, names):
        return {"sql_sources": {n: {"driver": "mysql", "host": "h",
                                     "database": "d", "query": "SELECT 1",
                                     "column_map": {"cost": "c"}} for n in names}}

    def test_report_all_sources_failed_exit2(self):
        from unittest import mock
        with mock.patch.object(llm_cost, "run_sql_source",
                               return_value=(None, "unreachable")), \
             mock.patch.object(llm_cost, "load_config",
                               return_value=self._cfg_with_sources(["a", "b"])):
            code, out = self._main(["report", "--json"])
        self.assertEqual(code, 2)
        payload = json.loads(out)
        self.assertEqual(len(payload["skipped"]), 2)

    def test_report_zero_cost_success_exit0(self):
        from unittest import mock
        with mock.patch.object(llm_cost, "run_sql_source",
                               return_value=([], None)), \
             mock.patch.object(llm_cost, "load_config",
                               return_value=self._cfg_with_sources(["a"])):
            code, out = self._main(["report", "--json"])
        self.assertEqual(code, 0)                     # 成功源 0 行 = 没花钱 ≠ 全挂
        payload = json.loads(out)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["rows"], [])

    def test_report_json_keys(self):
        from unittest import mock
        with mock.patch.object(llm_cost, "run_sql_source",
                               return_value=([], None)), \
             mock.patch.object(llm_cost, "load_config",
                               return_value=self._cfg_with_sources(["a"])), \
             mock.patch.object(llm_cost, "fetch_balance", return_value=None):
            code, out = self._main(["report", "--json"])
        payload = json.loads(out)
        for key in ("ok", "today", "rows", "totals", "balance", "skipped"):
            self.assertIn(key, payload)               # --json 公开契约(I5)

    def test_report_multisource_labels_and_subtotals(self):
        from datetime import date
        from unittest import mock

        def fake_run(name, cfg, days, today):
            rows = [{"day": str(date(2026, 11, 10)), "source": name,
                     "model": None, "cost": "10.00" if name == "a" else "2.00",
                     "currency": "CNY"}]
            return rows, None

        with mock.patch.object(llm_cost, "run_sql_source", side_effect=fake_run), \
             mock.patch.object(llm_cost, "load_config",
                               return_value=self._cfg_with_sources(["a", "b"])):
            code, out = self._main(["report", "--json"])
        payload = json.loads(out)
        sources = {r["source"] for r in payload["rows"]}
        self.assertEqual(sources, {"a", "b"})         # 行带源名(全源并列)
        self.assertEqual(payload["subtotals_by_source"]["a"]["CNY"], "10.00")
        self.assertEqual(payload["subtotals_by_source"]["b"]["CNY"], "2.00")

    def test_report_no_sources_guidance_exit0(self):
        from unittest import mock
        with mock.patch.object(llm_cost, "load_config", return_value={}):
            code, out = self._main(["report"])
        self.assertEqual(code, 0)                     # 判据⑩: 不炸, 引导文案
        self.assertIn("config.template", out)


class TestReviewFixPass(unittest.TestCase):
    """终审修复波(1C+4I): 每测对应评审发现, 先 RED 后 GREEN。"""

    def _main(self, argv):
        import io
        from contextlib import redirect_stdout
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = llm_cost.main(argv)
        return code, buf.getvalue()

    def test_f1_cli_col_flags_end_to_end(self):
        # Critical#1: --col-* 旗标经 CLI 端到端生效(此前键带 col_ 前缀全被忽略→静默¥0)
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "u.csv"
            p.write_text("d,m,tok_in,tok_out\n2026-11-10,deepseek-v4-flash,1000000,500000\n",
                         encoding="utf-8")
            code, out = self._main(["file", str(p), "--format", "csv", "--col-day", "d",
                                    "--col-model", "m", "--col-input-tokens", "tok_in",
                                    "--col-output-tokens", "tok_out"])
        self.assertEqual(code, 0)
        self.assertIn("1.70", out)

    def test_f2_hit_flag_documented_false_form(self):
        # Important#2: spec 文档形态 --hit-included-in-input false / =false 可用
        import tempfile
        row = ('{"model": "test-model", "input_tokens": 600000, '
               '"output_tokens": 500000, "cache_hit_tokens": 400000}\n')
        local = {"models": {"test-model": {"hit": 0.1, "miss": 1.0, "out": 1.0,
                                           "currency": "CNY"}}}
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            cfg_dir = home / ".claude" / "llm-cost"
            cfg_dir.mkdir(parents=True)
            (cfg_dir / "prices.json").write_text(json.dumps(local), encoding="utf-8")
            p = home / "u.jsonl"
            p.write_text(row, encoding="utf-8")
            with patch.object(Path, "home", return_value=home):
                code, out = self._main(["file", str(p),
                                        "--hit-included-in-input", "false"])
                code2, out2 = self._main(["file", str(p),
                                          "--hit-included-in-input=false"])
        self.assertEqual(code, 0)
        self.assertIn("1.14", out)                     # 0.04+0.6+0.5 (C1 对拍)
        self.assertEqual(code2, 0)
        self.assertIn("1.14", out2)

    def test_f3_cache_miss_inconsistency_all_miss(self):
        # Important#3: hit+miss≠input 不自洽 → 全记 miss(C1, 不虚构命中)
        rows = [{"model": "test-model", "input_tokens": 1_000_000,
                 "output_tokens": 0, "cache_hit_tokens": 400_000,
                 "cache_miss_tokens": 600_000},            # 自洽: 400+600==1000k
                {"model": "test-model", "input_tokens": 1_000_000,
                 "output_tokens": 0, "cache_hit_tokens": 800_000,
                 "cache_miss_tokens": 600_000}]            # 不自洽: 800+600≠1000k
        agg = llm_cost.aggregate_rows(rows, _prices_with_test_model())
        # 行1 自洽 0.04+0.6=0.64; 行2 全 miss 1.0 → 1.64 (未实现时 1.32)
        self.assertEqual(agg["total"], Decimal("1.64"))

    def test_f3b_col_cache_miss_flag_exists(self):
        # Important#3 附: --col-cache-miss-tokens 旗标存在(标准列第9列)
        code, out = self._main(["file", "Z:/nope.jsonl",
                                "--col-cache-miss-tokens", "cm"])
        self.assertNotIn("unrecognized arguments", out)
        self.assertEqual(code, 1)                      # 到达的应是"文件不存在"

    def test_f4_sql_days_config_precedence(self):
        # Important#4: sql 子命令 --days 同守 I6 优先级(CLI>config defaults>7)
        from datetime import date
        from unittest import mock
        seen = {}

        def fake_run(name, cfg, days, today):
            seen["days"] = days
            return [], None

        cfg = {"defaults": {"days": 30},
               "sql_sources": {"prod": {"driver": "mysql", "host": "h",
                                        "database": "d", "query": "SELECT 1",
                                        "column_map": {"cost": "c"}}}}
        with mock.patch.object(llm_cost, "run_sql_source", side_effect=fake_run), \
             mock.patch.object(llm_cost, "load_config", return_value=cfg):
            code, _ = self._main(["sql", "--name", "prod"])
        self.assertEqual(code, 0)
        self.assertEqual(seen["days"], 30)             # 非 7

    def test_f5_corrupt_local_prices_clean_error(self):
        # Important#5: 本地 prices.json 损坏 → 明错 exit 1(不静默回退仓内价)
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            cfg_dir = home / ".claude" / "llm-cost"
            cfg_dir.mkdir(parents=True)
            (cfg_dir / "prices.json").write_text('{"models": {,}}', encoding="utf-8")
            with patch.object(Path, "home", return_value=home):
                code, out = self._main(["calc", "--model", "deepseek-v4-flash",
                                        "--input", "1000000", "--output", "500000"])
        self.assertEqual(code, 1)
        self.assertIn("[错误]", out)
        self.assertIn("prices.json", out)


if __name__ == "__main__":
    unittest.main()
