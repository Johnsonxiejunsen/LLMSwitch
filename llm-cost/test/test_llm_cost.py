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


if __name__ == "__main__":
    unittest.main()
