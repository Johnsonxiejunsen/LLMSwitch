#!/usr/bin/env python3
"""llm-cost — 通用 LLM 使用成本计算(单文件, stdlib + 可选 pymysql)。

数据流: 各数据源(手报/文件/SQL/余额) → 标准行 dict → 计算内核(单价注册表×token 分档)。
口径与契约见仓内 spec: docs/features/llm-cost/specs/llm-cost.md(v1.1)。
"""
from __future__ import annotations

import json
from decimal import Decimal
from pathlib import Path

_M = Decimal(10 ** 6)  # 每百万 token 单位


class UnknownModelError(Exception):
    """模型不在价格注册表(别名解析后仍无)——calc 场景应为业务错误。"""


# ── 价格注册表: 仓内预置 + 本地覆盖合并(同模型键本地赢, aliases 逐键) ──

def _bundled_prices_path() -> Path:
    return Path(__file__).resolve().parent.parent / "data" / "prices.json"


def _local_prices_path() -> Path:
    return Path.home() / ".claude" / "llm-cost" / "prices.json"


def load_prices() -> dict:
    """载入注册表: json.load(parse_float=Decimal) 防浮点污染; 本地文件存在则合并。"""
    with open(_bundled_prices_path(), encoding="utf-8") as f:
        prices = json.load(f, parse_float=Decimal)
    local_path = _local_prices_path()
    if local_path.exists():
        try:
            with open(local_path, encoding="utf-8") as f:
                local = json.load(f, parse_float=Decimal)
        except (OSError, json.JSONDecodeError):
            local = {}
        prices["models"] = {**prices.get("models", {}), **local.get("models", {})}
        prices["aliases"] = {**prices.get("aliases", {}), **local.get("aliases", {})}
    return prices


def normalize_model(name: str | None, prices: dict) -> str:
    """别名→正式名; 未知(含 None)raise UnknownModelError。"""
    resolved = prices.get("aliases", {}).get(name or "", name)
    if resolved not in prices.get("models", {}):
        raise UnknownModelError(str(name))
    return resolved


# ── 计算内核(纯函数) ──

def cost_from_tokens(model: str, input_tokens: int, output_tokens: int,
                     cache_hit_tokens: int = 0, *,
                     hit_included_in_input: bool = True,
                     prices: dict | None = None) -> Decimal:
    """¥ = hit/1M×hit价 + miss/1M×miss价 + out/1M×out价。

    默认口径: input_tokens 已含 cache hit(DeepSeek/OpenAI) → hit=min(cache_hit, input)。
    hit_included_in_input=False(Anthropic 形态, input 不含 cache_read):
    hit=cache_hit, miss=input_tokens。
    """
    pr = prices or load_prices()
    p = pr["models"][normalize_model(model, pr)]
    inp = max(0, int(input_tokens))
    out = max(0, int(output_tokens))
    hit = max(0, int(cache_hit_tokens))
    if hit_included_in_input:
        hit = min(hit, inp)
        miss = inp - hit
    else:
        miss = inp
    return (Decimal(hit) / _M * p["hit"]
            + Decimal(miss) / _M * p["miss"]
            + Decimal(out) / _M * p["out"])
