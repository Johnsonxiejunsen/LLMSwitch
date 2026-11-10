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


if __name__ == "__main__":
    unittest.main()
