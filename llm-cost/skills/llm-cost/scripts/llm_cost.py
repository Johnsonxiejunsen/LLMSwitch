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


# ── 文件数据源(JSONL/CSV → 标准行) ──

STANDARD_COLUMNS = ("day", "source", "model", "input_tokens", "output_tokens",
                    "cache_hit_tokens", "cache_miss_tokens", "cost", "currency")


def parse_file_rows(path: str, fmt: str | None = None,
                    col_map: dict | None = None) -> list[dict]:
    """JSONL(每行一对象)/CSV(首行表头) → 标准行 dict 列表。

    fmt 缺省按扩展名嗅探(.csv→csv, 其余 jsonl); col_map 键=标准列名, 值=文件列名;
    文件不存在 raise FileNotFoundError(调用方按业务错误处理)。
    """
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(path)
    f = (fmt or ("csv" if p.suffix.lower() == ".csv" else "jsonl")).lower()
    raw: list[dict] = []
    if f == "csv":
        import csv
        with open(p, encoding="utf-8-sig", newline="") as fh:
            raw = [dict(r) for r in csv.DictReader(fh)]
    elif f == "jsonl":
        with open(p, encoding="utf-8") as fh:
            raw = [json.loads(line) for line in fh if line.strip()]
    else:
        raise ValueError(f"不支持的 format: {f}(jsonl|csv)")
    mapping = dict(col_map or {})
    rows: list[dict] = []
    for item in raw:
        row: dict = {}
        for col in STANDARD_COLUMNS:
            val = item.get(mapping.get(col, col))
            if val is not None and val != "":
                row[col] = val
        rows.append(row)
    return rows


def aggregate_rows(rows: list[dict], prices: dict, *,
                   hit_included_in_input: bool = True) -> dict:
    """标准行聚合: 计价(model 路径)/直通(cost 路径) + 未知模型跳过计数。

    返回 {"total", "totals_by_currency", "per_day", "skipped_unknown_models",
    "unknown_models"}; per_day 行键=天×来源×模型(spec M9)。
    """
    total = Decimal(0)
    totals: dict[str, Decimal] = {}
    per_day: dict[tuple, dict] = {}
    skipped = 0
    unknown: list[str] = []

    def _add(day, source, model, cost, currency):
        nonlocal total
        total += cost
        totals[currency] = totals.get(currency, Decimal(0)) + cost
        key = (str(day) if day is not None else None,
               str(source) if source is not None else None,
               str(model) if model is not None else None)
        if key in per_day:
            per_day[key]["cost"] += cost
        else:
            per_day[key] = {"day": key[0], "source": key[1], "model": key[2],
                            "cost": cost, "currency": currency}

    for r in rows:
        model, cost = r.get("model"), r.get("cost")
        if cost is not None:                      # 直通行: 信任库内已算金额
            _add(r.get("day"), r.get("source"), model,
                 Decimal(str(cost)), str(r.get("currency") or "CNY"))
            continue
        if model is None:                          # 既无 model 也无 cost → 跳过计数
            skipped += 1
            continue
        try:
            key = normalize_model(str(model), prices)
        except UnknownModelError:
            skipped += 1
            unknown.append(str(model))
            continue
        c = cost_from_tokens(
            key, int(r.get("input_tokens") or 0), int(r.get("output_tokens") or 0),
            int(r.get("cache_hit_tokens") or 0),
            hit_included_in_input=hit_included_in_input, prices=prices)
        _add(r.get("day"), r.get("source"), key, c,
             str(prices["models"][key].get("currency") or "CNY"))

    return {"total": total,
            "totals_by_currency": totals,
            "per_day": sorted(per_day.values(),
                              key=lambda x: (x["day"] or "", x["source"] or ""),
                              reverse=True),
            "skipped_unknown_models": skipped,
            "unknown_models": unknown}
