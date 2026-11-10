#!/usr/bin/env python3
"""llm-cost — 通用 LLM 使用成本计算(单文件, stdlib + 可选 pymysql)。

数据流: 各数据源(手报/文件/SQL/余额) → 标准行 dict → 计算内核(单价注册表×token 分档)。
口径与契约见仓内 spec: docs/features/llm-cost/specs/llm-cost.md(v1.1)。
"""
from __future__ import annotations

import json
import sys
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
        except json.JSONDecodeError as e:   # 损坏≠不存在: 静默回退会让校准价变仓内价(Important#5)
            raise ValueError(
                f"本地价格文件不可解析: {local_path}({e}) —— 修正或删除后重试") from e
        except OSError:
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
        hit_tok = int(r.get("cache_hit_tokens") or 0)
        in_tok = int(r.get("input_tokens") or 0)
        # C1 自洽校验(默认口径): 提供 cache_miss 列且 hit+miss≠input → 全记 miss, 不虚构命中
        miss_tok = r.get("cache_miss_tokens")
        if (hit_included_in_input and miss_tok is not None
                and hit_tok + int(miss_tok) != in_tok):
            hit_tok = 0
        c = cost_from_tokens(
            key, in_tok, int(r.get("output_tokens") or 0),
            hit_tok,
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


# ── SQL 源配置链(纯函数, 不连库) ──

class SourceConfigError(Exception):
    """SQL 源 column_map 违反必填规则((model+input+output) 或 cost 二选一)。"""

_SKIP_REASONS = ("not_configured", "unreachable", "timeout",
                 "auth_failed", "query_failed", "no_sources")


def load_config() -> dict:
    """~/.claude/llm-cost/config.json; 不存在返回 {}。"""
    path = Path.home() / ".claude" / "llm-cost" / "config.json"
    if not path.exists():
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise ValueError(f"配置文件不可解析({path}): {e}") from e


def resolve_secret(cfg: dict, plain_key: str = "password",
                   env_key: str = "password_env") -> str | None:
    """env 变量引用优先于明文; 都缺返回 None。"""
    env_name = cfg.get(env_key)
    if env_name:
        import os
        val = os.environ.get(str(env_name))
        if val:
            return val
    plain = cfg.get(plain_key)
    return str(plain) if plain else None


def date_window(days: int, today) -> tuple:
    """(start, end) = (今日−(days−1), 今日+1), 含首不含尾(DATETIME 安全, spec I1)。"""
    from datetime import timedelta
    days = max(1, int(days))
    return today - timedelta(days=days - 1), today + timedelta(days=1)


def substitute_placeholders(query: str, days: int, today) -> str:
    """仅字面替换 {start_date}/{end_date}/{days} 三 token, 其余大括号原样(禁 str.format)。"""
    start, end = date_window(days, today)
    return (query.replace("{start_date}", start.isoformat())
                 .replace("{end_date}", end.isoformat())
                 .replace("{days}", str(days)))


def transform_sql_rows(raw_rows: list[dict], column_map: dict,
                       source_name: str) -> list[dict]:
    """SQL 结果列 → 标准行; source 加 `源名:` 前缀; 必填规则校验(违者 SourceConfigError)。

    column_map 键=标准列名, 值=SQL 列名; 未映射的标准列按同名列取, 取不到缺省。
    """
    mapping = dict(column_map or {})
    rows: list[dict] = []
    for raw in raw_rows:
        row: dict = {}
        for col in STANDARD_COLUMNS:
            val = raw.get(mapping.get(col, col))
            if val is not None:
                row[col] = val
        has_cost = "cost" in row
        has_priced = all(k in row for k in ("model", "input_tokens", "output_tokens"))
        if not (has_cost or has_priced):
            raise SourceConfigError(
                f"源 {source_name!r} column_map 违反必填规则: "
                f"需 (model+input_tokens+output_tokens) 或 cost 二选一, 实得列 {sorted(row)}")
        raw_src = row.get("source")
        row["source"] = f"{source_name}:{raw_src}" if raw_src else source_name
        rows.append(row)
    return rows


# ── SQL 执行 + DeepSeek 余额(可连真实端; 超时=跳过不挂死) ──

def _classify_connect_error(exc: Exception) -> str:
    s = str(exc)
    if "1045" in s or "access denied" in s.lower():
        return "auth_failed"
    if "timed out" in s.lower() or "timeout" in s.lower() or "2013" in s:
        return "timeout"
    return "unreachable"


def run_sql_source(name: str, cfg: dict, days: int, today) -> tuple:
    """跑一个命名 SQL 源 → (标准行, None) 或 (None, skip_reason)。

    reason ∈ not_configured/unreachable/timeout/auth_failed/query_failed;
    连接超时 5s / 读超时 10s(spec I8)。
    """
    try:
        import pymysql
    except ImportError:
        print("[hint] SQL 源需要驱动: pip install pymysql")
        return None, "not_configured"
    if not cfg or cfg.get("driver", "mysql") != "mysql":
        return None, "not_configured"
    if not all(cfg.get(k) for k in ("host", "database", "query")):
        return None, "not_configured"
    password = resolve_secret(cfg)
    q = substitute_placeholders(str(cfg["query"]), days, today)
    try:
        conn = pymysql.connect(
            host=cfg["host"], port=int(cfg.get("port", 3306)),
            user=cfg.get("user", ""), password=password,
            database=cfg["database"], charset="utf8mb4",
            connect_timeout=5, read_timeout=10,
            cursorclass=pymysql.cursors.DictCursor)
    except Exception as e:  # noqa: BLE001 —— 分类为跳过原因, 不挂死
        return None, _classify_connect_error(e)
    try:
        with conn.cursor() as cur:
            cur.execute(q)
            raw = cur.fetchall()
    except Exception:  # noqa: BLE001
        return None, "query_failed"
    finally:
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass
    try:
        return transform_sql_rows([dict(r) for r in raw],
                                  cfg.get("column_map") or {}, name), None
    except SourceConfigError:
        return None, "not_configured"


def fetch_balance(cfg: dict, timeout: float = 5.0) -> dict | None:
    """DeepSeek GET /user/balance(唯一账务接口); 无 key/失败返回 None(fail-open)。"""
    import urllib.request
    key = resolve_secret(cfg, plain_key="api_key", env_key="api_key_env")
    if not key:
        return None
    base = str(cfg.get("base_url") or "https://api.deepseek.com").rstrip("/")
    origin = base[:-3] if base.endswith("/v1") else base
    try:
        req = urllib.request.Request(
            f"{origin}/user/balance",
            headers={"Authorization": f"Bearer {key}"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            d = json.loads(r.read())
        infos = {b.get("currency"): Decimal(str(b.get("total_balance", 0)))
                 for b in d.get("balance_infos", [])}
        from datetime import datetime
        return {"is_available": d.get("is_available"),
                "total_balance": infos,
                "checked_at": datetime.now().isoformat(timespec="seconds")}
    except Exception:  # noqa: BLE001 —— 余额失败不影响主流程
        return None


# ── CLI(calc / file / sql / balance / report) ──

import argparse  # noqa: E402


class _UsageError(Exception):
    """argparse 用法错误 → main 返回 1(spec C2; argparse 默认 exit 2 会与"全源失败"混淆)。"""


class _Parser(argparse.ArgumentParser):
    def error(self, message):  # pragma: no cover —— 由 test_argparse_usage_error_exit1 覆盖
        raise _UsageError(message)


def _parse_hit_flag(v):
    """--hit-included-in-input 取值: true/false/1/0/yes/no(裸旗标=const True)。"""
    if isinstance(v, bool):
        return v
    s = str(v).strip().lower()
    if s in ("true", "1", "yes", "y"):
        return True
    if s in ("false", "0", "no", "n"):
        return False
    raise _UsageError(f"--hit-included-in-input 需 true/false, 收到 {v!r}")


def _add_file_opts(sp):
    sp.add_argument("--format", choices=["jsonl", "csv"], default=None)
    for col in ("day", "source", "model", "input-tokens", "output-tokens",
                "cache-hit-tokens", "cache-miss-tokens", "cost", "currency"):
        sp.add_argument(f"--col-{col}", default=None)
    sp.add_argument("--hit-included-in-input", nargs="?", const=True, default=True,
                    type=_parse_hit_flag)
    sp.add_argument("--json", action="store_true")


def _col_map_from_args(args) -> dict:
    # dest 形如 col_day/col_input_tokens → 剥 col_ 前缀得标准列名(Critical#1)
    return {c[len("col_"):]: v for c, v in vars(args).items()
            if c.startswith("col_") and v is not None}


def _fmt(d: Decimal, places: int = 4) -> str:
    return f"{d:.{places}f}"


def _merge_agg(base: dict, extra: dict) -> dict:
    base["total"] += extra["total"]
    for cur, v in extra["totals_by_currency"].items():
        base["totals_by_currency"][cur] = base["totals_by_currency"].get(cur, Decimal(0)) + v
    for row in extra["per_day"]:
        key = (row["day"], row["source"], row["model"])
        hit = next((r for r in base["per_day"]
                    if (r["day"], r["source"], r["model"]) == key), None)
        if hit:
            hit["cost"] += row["cost"]
        else:
            base["per_day"].append(dict(row))
    base["skipped_unknown_models"] += extra["skipped_unknown_models"]
    base["unknown_models"] += extra["unknown_models"]
    return base


def _empty_agg() -> dict:
    return {"total": Decimal(0), "totals_by_currency": {}, "per_day": [],
            "skipped_unknown_models": 0, "unknown_models": []}


def _cmd_calc(args) -> int:
    prices = load_prices()
    try:
        key = normalize_model(args.model, prices)
        cost = cost_from_tokens(key, args.input, args.output,
                                cache_hit_tokens=args.cache_hit or 0,
                                hit_included_in_input=args.hit_included_in_input,
                                prices=prices)
    except UnknownModelError:
        known = ", ".join(sorted(prices["models"]))
        print(f"[错误] 未知模型 {args.model!r}。可用: {known}; "
              f"加新模型: ~/.claude/llm-cost/prices.json(本地覆盖, 见 SKILL.md)")
        return 1
    currency = prices["models"][key].get("currency", "CNY")
    if args.json:
        print(json.dumps({"model": key, "input_tokens": args.input,
                          "output_tokens": args.output,
                          "cache_hit_tokens": args.cache_hit or 0,
                          "cost": _fmt(cost), "currency": currency},
                         ensure_ascii=False))
    else:
        print(f"¥{_fmt(cost)} ({currency}, {key})")
    return 0


def _cmd_file(args) -> int:
    try:
        rows = parse_file_rows(args.path, fmt=args.format,
                               col_map=_col_map_from_args(args))
    except FileNotFoundError:
        print(f"[错误] 文件不存在: {args.path}")
        return 1
    except ValueError as e:
        print(f"[错误] {e}")
        return 1
    agg = aggregate_rows(rows, load_prices(),
                         hit_included_in_input=args.hit_included_in_input)
    if args.json:
        print(json.dumps(agg, ensure_ascii=False, default=str))
        return 0
    print(f"合计: " + ", ".join(f"{cur} {v:.2f}"
                                for cur, v in agg["totals_by_currency"].items()))
    for r in agg["per_day"]:
        model = r["model"] or "(未分模型)"
        print(f"  {r['day'] or '-'}  {r['source'] or '-'}  {model}  {_fmt(r['cost'])}")
    if agg["skipped_unknown_models"]:
        names = ", ".join(agg["unknown_models"])
        print(f"skipped_unknown_models={agg['skipped_unknown_models']} ({names})")
    return 0


def _cmd_sql(args) -> int:
    config = load_config()
    sources = config.get("sql_sources") or {}
    cfg = sources.get(args.name)
    if not cfg:
        print(f"[skipped] sql 源 {args.name!r} 不存在(not_configured)")
        return 1
    from datetime import date
    rows, reason = run_sql_source(
        args.name, cfg,
        args.days if args.days is not None
        else int((config.get("defaults") or {}).get("days", 7)),  # I6: CLI>config>7
        date.today())
    if reason:
        print(f"[skipped] sql 源 {args.name!r}: {reason}")
        return 0 if reason != "not_configured" else 1
    agg = aggregate_rows(rows, load_prices(),
                         hit_included_in_input=bool(cfg.get("hit_included_in_input", True)))
    print(json.dumps(agg, ensure_ascii=False, default=str))
    return 0


def _cmd_balance(args) -> int:
    out = fetch_balance(load_config().get("deepseek") or {})
    if out is None:
        print("[skipped] DeepSeek 余额未配置 key 或查询失败")
        return 0
    parts = ", ".join(f"{cur} {v}" for cur, v in out["total_balance"].items())
    print(f"余额: {parts}(is_available={out['is_available']}, "
          f"账号级含其它服务消耗仅参考, checked_at={out['checked_at']})")
    return 0


def build_report(config: dict, days: int, source_spec: str = "auto",
                 file_opts=None) -> dict:
    """report 默认视图编排: 全部 SQL 源并列(sql:NAME 收窄)/file 源 + 余额。"""
    from datetime import date
    today = date.today()
    agg = _empty_agg()
    skipped: list[dict] = []
    attempted = 0

    if source_spec.startswith("file:"):
        path = source_spec[len("file:"):]
        attempted = 1
        try:
            fo = file_opts
            rows = parse_file_rows(path, fmt=getattr(fo, "format", None),
                                   col_map=_col_map_from_args(fo) if fo else {})
            part = aggregate_rows(rows, load_prices(),
                                  hit_included_in_input=getattr(
                                      fo, "hit_included_in_input", True))
            agg = _merge_agg(agg, part)
        except (FileNotFoundError, ValueError):
            skipped.append({"source": f"file:{path}", "reason": "not_configured"})
    else:
        sources = config.get("sql_sources") or {}
        if source_spec == "auto":
            selected = list(sources.items())
        elif source_spec.startswith("sql:"):
            name = source_spec[len("sql:"):]
            selected = [(name, sources[name])] if name in sources else []
            if not selected:
                skipped.append({"source": f"sql:{name}", "reason": "not_configured"})
                attempted = 1
        else:
            selected = []
        for name, cfg in selected:
            attempted += 1
            rows, reason = run_sql_source(name, cfg, days, today)
            if reason:
                skipped.append({"source": f"sql:{name}", "reason": reason})
                continue
            part = aggregate_rows(
                rows, load_prices(),
                hit_included_in_input=bool(cfg.get("hit_included_in_input", True)))
            agg = _merge_agg(agg, part)

    succeeded = attempted - len(skipped)
    today_str = str(today)
    today_cost: dict[str, Decimal] = {}
    for r in agg["per_day"]:
        if r["day"] == today_str:
            today_cost[r["currency"]] = today_cost.get(r["currency"], Decimal(0)) + r["cost"]
    subtotals: dict[str, dict[str, Decimal]] = {}
    for r in agg["per_day"]:
        base = (r["source"] or "?").split(":")[0]
        subtotals.setdefault(base, {})
        subtotals[base][r["currency"]] = subtotals[base].get(r["currency"], Decimal(0)) + r["cost"]

    return {"ok": attempted == 0 or succeeded > 0,
            "days": days,
            "attempted": attempted, "succeeded": succeeded,
            "today": {"date": today_str,
                      "cost_by_currency": {k: _fmt(v, 2) for k, v in today_cost.items()}},
            "rows": agg["per_day"],
            "totals": {k: _fmt(v, 2) for k, v in agg["totals_by_currency"].items()},
            "subtotals_by_source": {s: {c: _fmt(v, 2) for c, v in cur.items()}
                                    for s, cur in subtotals.items()},
            "balance": fetch_balance(config.get("deepseek") or {}),
            "skipped": skipped,
            "skipped_unknown_models": agg["skipped_unknown_models"],
            "unknown_models": agg["unknown_models"]}


def render_report(report: dict) -> str:
    lines: list[str] = []
    if report["attempted"] == 0:
        return ("未发现可用数据源。首次使用: 复制 config.template.json 到 "
                "~/.claude/llm-cost/config.json 并填写(见 SKILL.md); "
                "或直接 file/calc 算一笔\n")
    today_parts = ", ".join(f"{cur} {v}" for cur, v in report["today"]["cost_by_currency"].items())
    lines.append(f"今日({report['today']['date']}) LLM 成本: {today_parts or '¥0.00'}")
    lines.append(f"近 {report['days']} 天(天×来源×模型):")
    for r in sorted(report["rows"], key=lambda x: (x["day"] or "", x["source"] or ""),
                    reverse=True):
        lines.append(f"  {r['day'] or '-'}  {r['source'] or '-'}  "
                     f"{r['model'] or '(未分模型)'}  {_fmt(r['cost'])}")
    for src, cur_map in report["subtotals_by_source"].items():
        parts = ", ".join(f"{cur} {v}" for cur, v in cur_map.items())
        lines.append(f"  小计[{src}]: {parts}")
    totals = ", ".join(f"{cur} {v}" for cur, v in report["totals"].items())
    lines.append(f"合计: {totals or '¥0.00'}")
    bal = report["balance"]
    if bal:
        parts = ", ".join(f"{cur} {v}" for cur, v in bal["total_balance"].items())
        lines.append(f"余额: {parts}(账号级, 含其它服务消耗, 仅参考)")
    for s in report["skipped"]:
        lines.append(f"[skipped] {s['source']}: {s['reason']} → 已跳过, 其余照常")
    if report["skipped_unknown_models"]:
        lines.append(f"未知模型行已跳过 ×{report['skipped_unknown_models']}"
                     f" ({', '.join(report['unknown_models'])})")
    return "\n".join(lines) + "\n"


def _cmd_report(args) -> int:
    config = load_config()
    days = args.days
    if days is None:
        days = int((config.get("defaults") or {}).get("days", 7))
    spec = args.source or "auto"
    file_opts = args if spec.startswith("file:") else None
    report = build_report(config, days, spec, file_opts)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, default=str))
    else:
        print(render_report(report), end="")
    if report["attempted"] == 0:
        return 0            # 未配置任何源: 引导而非失败(spec 判据⑩)
    return 0 if report["succeeded"] > 0 else 2


def _build_parser() -> argparse.ArgumentParser:
    p = _Parser(prog="llm_cost", description="通用 LLM 使用成本计算")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("calc", help="手报 token 数直算一笔")
    sp.add_argument("--model", required=True)
    sp.add_argument("--input", type=int, required=True)
    sp.add_argument("--output", type=int, required=True)
    sp.add_argument("--cache-hit", type=int, default=0)
    sp.add_argument("--hit-included-in-input", nargs="?", const=True, default=True,
                    type=_parse_hit_flag)
    sp.add_argument("--json", action="store_true")
    sp.set_defaults(func=_cmd_calc)

    sp = sub.add_parser("file", help="JSONL/CSV 用量文件汇总")
    sp.add_argument("path")
    _add_file_opts(sp)
    sp.set_defaults(func=_cmd_file)

    sp = sub.add_parser("sql", help="按本地配置跑命名 SQL 源")
    sp.add_argument("--name", required=True)
    sp.add_argument("--days", type=int, default=None)
    sp.set_defaults(func=_cmd_sql)

    sp = sub.add_parser("balance", help="DeepSeek 官方余额(需配置 key)")
    sp.set_defaults(func=_cmd_balance)

    sp = sub.add_parser("report", help="默认视图: 今日+近N天×来源+余额")
    sp.add_argument("--days", type=int, default=None)
    sp.add_argument("--source", default="auto",
                    help="auto=全部 SQL 源并列 | sql:<名> | file:<路径>")
    _add_file_opts(sp)
    sp.set_defaults(func=_cmd_report)
    return p


def _harden_streams():
    """Windows GBK 管道下 ¥(U+00A5) 不可编码会崩 — 统一 utf-8(errors=replace)。

    真控制台走 WriteConsoleW 不受影响; 管道消费方(Claude/CI)按 utf-8 读, 中文也正。
    """
    for s in (sys.stdout, sys.stderr):
        try:
            s.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError, OSError):  # StringIO(测试)/已关流
            pass


def main(argv: list[str] | None = None) -> int:
    _harden_streams()
    try:
        args = _build_parser().parse_args(argv)
        return args.func(args)
    except _UsageError as e:
        print(f"[用法错误] {e}", file=sys.stderr)
        return 1
    except ValueError as e:   # 配置不可解析/脏数据格式错 → 明错而非回溯(C2: 业务错=1)
        print(f"[错误] {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
