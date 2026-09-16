#!/usr/bin/env python3
"""Aggregate local Claude Code and Codex transcripts: where and on what the
tokens went.

Token counts are exact (read straight out of each turn's usage record).
Dollar figures are an estimate: Claude token counts priced at public API rates.
Codex publishes no per-token rate for subscription plans, so its rows carry
tokens only and a cost of 0.

Emits TSV:  KIND \t name \t tokens \t cost \t messages \t padded-name \t priced

`priced` is 0 when no published rate is known for that model, in which case
`cost` is 0 and the totals are a floor rather than an estimate.

KIND is TOTAL / PROJ / MODEL for Claude, and the same three prefixed with
CODEX_ or GROK_ for the other two.

The padded name is pre-fitted to a fixed number of terminal columns, counting
East Asian wide characters as two, so the caller can print it verbatim.
"""
import json, os, sys, time, unicodedata, urllib.parse

NAME_COLS = 24


def dwidth(s):
    return sum(2 if unicodedata.east_asian_width(ch) in "WF" else 1 for ch in s)


def fit(s, cols=NAME_COLS):
    if dwidth(s) <= cols:
        return s + " " * (cols - dwidth(s))
    out, used = "", 3  # leave room for the leading ellipsis
    for ch in reversed(s):
        w = 2 if unicodedata.east_asian_width(ch) in "WF" else 1
        if used + w > cols:
            break
        out = ch + out
        used += w
    return "..." + out + " " * (cols - used)

# $ per million tokens: input, output, cache-read
PRICES = (
    ("claude-fable-5-1",  10.0, 50.0, 0.25),
    ("claude-mythos-5-1", 10.0, 50.0, 0.25),
    ("claude-fable-5",    10.0, 50.0, 1.00),
    ("claude-mythos-5",   10.0, 50.0, 1.00),
    ("claude-opus-5",      5.0, 25.0, 0.50),
    ("claude-opus-4",      5.0, 25.0, 0.50),
    ("claude-sonnet-5",    2.0, 10.0, 0.20),
    ("claude-sonnet-4-6",  3.0, 15.0, 0.30),
    ("claude-haiku-4",     1.0,  5.0, 0.10),
)


def price_for(model):
    """Returns None for a model the table has never seen.

    Guessing a rate would put a confident wrong dollar figure on screen, which
    is worse than admitting the gap - so unpriced models are counted in tokens
    and left out of the cost.
    """
    for prefix, pin, pout, pread in PRICES:
        if model.startswith(prefix):
            return pin, pout, pread
    return None


def window(days):
    """Start of the reporting window: local midnight for a day, else rolling."""
    now = time.time()
    if days <= 1:
        lt = time.localtime(now)
        return time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))
    return now - days * 86400


def parse_ts(text):
    try:
        return time.mktime(time.strptime(text[:19], "%Y-%m-%dT%H:%M:%S")) - time.timezone
    except Exception:
        return None


def scan_codex(root, start):
    """Codex records a per-turn token delta, so attribution is exact."""
    projects, models = {}, {}
    total_tok = total_msgs = 0
    file_cutoff = start - 86400

    for dirpath, _, names in os.walk(root):
        for nm in names:
            if not (nm.startswith("rollout-") and nm.endswith(".jsonl")):
                continue
            path = os.path.join(dirpath, nm)
            try:
                if os.path.getmtime(path) < file_cutoff:
                    continue
            except OSError:
                continue

            proj, model = "~", "unknown"
            try:
                fh = open(path, "r", encoding="utf-8", errors="replace")
            except OSError:
                continue
            with fh as f:
                for line in f:
                    if '"cwd"' not in line and '"model"' not in line \
                            and '"token_count"' not in line:
                        continue
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    payload = rec.get("payload")
                    if not isinstance(payload, dict):
                        continue

                    kind = rec.get("type")
                    if kind in ("session_meta", "turn_context"):
                        cwd = payload.get("cwd")
                        if isinstance(cwd, str) and cwd:
                            proj = os.path.basename(cwd) or "~"
                        if payload.get("model"):
                            model = payload["model"]
                        continue

                    if payload.get("type") != "token_count":
                        continue
                    info = payload.get("info") or {}
                    last = info.get("last_token_usage") or {}
                    tok = last.get("total_tokens") or 0
                    if not tok:
                        continue
                    epoch = parse_ts(rec.get("timestamp") or "")
                    if epoch is None or epoch < start:
                        continue

                    p = projects.setdefault(proj, [0, 0.0, 0])
                    p[0] += tok; p[2] += 1
                    m = models.setdefault(model, [0, 0.0, 0])
                    m[0] += tok; m[2] += 1
                    total_tok += tok; total_msgs += 1

    return projects, models, total_tok, total_msgs


def scan_grok(root, start):
    """Grok writes one usage record per turn, and they sum to the session total.

    Each record carries a millisecond timestamp, so turns land in the right
    window even when a session spans days. xAI publishes no per-token rate for
    the subscription, and the cost it records is in undocumented "ticks", so
    these rows report tokens only.
    """
    projects, models = {}, {}
    total_tok = total_msgs = 0
    start_ms = start * 1000

    for cwd_entry in sorted(os.listdir(root)) if os.path.isdir(root) else []:
        cwd_dir = os.path.join(root, cwd_entry)
        if not os.path.isdir(cwd_dir):
            continue
        # Directory names are the percent-encoded working directory.
        decoded = urllib.parse.unquote(cwd_entry)
        proj = os.path.basename(decoded.rstrip("/")) or "~"

        for session in sorted(os.listdir(cwd_dir)):
            updates = os.path.join(cwd_dir, session, "updates.jsonl")
            try:
                if os.path.getmtime(updates) < start - 86400:
                    continue
            except OSError:
                continue
            try:
                fh = open(updates, "r", encoding="utf-8", errors="replace")
            except OSError:
                continue
            with fh as f:
                for line in f:
                    if '"usage"' not in line:
                        continue
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    params = rec.get("params") or {}
                    usage = (params.get("update") or {}).get("usage")
                    if not isinstance(usage, dict):
                        continue
                    tok = usage.get("totalTokens") or 0
                    if not tok:
                        continue
                    stamp = (params.get("_meta") or {}).get("agentTimestampMs")
                    if not isinstance(stamp, (int, float)) or stamp < start_ms:
                        continue

                    p = projects.setdefault(proj, [0, 0.0, 0])
                    p[0] += tok; p[2] += 1
                    per_model = usage.get("modelUsage")
                    if isinstance(per_model, dict) and per_model:
                        for name, stats in per_model.items():
                            if not isinstance(stats, dict):
                                continue
                            m = models.setdefault(name, [0, 0.0, 0])
                            m[0] += stats.get("totalTokens") or 0
                            m[2] += 1
                    else:
                        m = models.setdefault("grok", [0, 0.0, 0])
                        m[0] += tok; m[2] += 1
                    total_tok += tok; total_msgs += 1

    return projects, models, total_tok, total_msgs


def main():
    root = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/.claude/projects")
    days = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
    codex_root = os.path.expanduser(
        sys.argv[3] if len(sys.argv) > 3 else "~/.codex/sessions")
    grok_root = os.path.expanduser(
        sys.argv[4] if len(sys.argv) > 4 else "~/.grok/sessions")

    now = time.time()
    start = window(days)
    file_cutoff = start - 86400  # mtime is the last write, so keep a day of slack

    seen = set()
    unpriced = set()
    unpriced_projects = set()
    projects, models = {}, {}
    total_tok = total_cost = total_msgs = 0

    for dirpath, _, names in os.walk(root):
        for nm in names:
            if not nm.endswith(".jsonl"):
                continue
            path = os.path.join(dirpath, nm)
            try:
                if os.path.getmtime(path) < file_cutoff:
                    continue
            except OSError:
                continue

            fallback = os.path.basename(dirpath)
            try:
                fh = open(path, "r", encoding="utf-8", errors="replace")
            except OSError:
                continue
            with fh as f:
                for line in f:
                    if '"usage"' not in line:
                        continue
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    msg = rec.get("message")
                    if not isinstance(msg, dict):
                        continue
                    usage = msg.get("usage")
                    model = msg.get("model")
                    if not isinstance(usage, dict) or not model or model == "<synthetic>":
                        continue

                    ts = rec.get("timestamp")
                    if not ts:
                        continue
                    epoch = parse_ts(ts)
                    if epoch is None or epoch < start:
                        continue

                    key = (msg.get("id") or "", rec.get("requestId") or "")
                    if key != ("", "") and key in seen:
                        continue
                    seen.add(key)

                    cc = usage.get("cache_creation") or {}
                    w5 = cc.get("ephemeral_5m_input_tokens")
                    if w5 is None:
                        w5 = usage.get("cache_creation_input_tokens") or 0
                    w1h = cc.get("ephemeral_1h_input_tokens") or 0
                    tin = usage.get("input_tokens") or 0
                    tout = usage.get("output_tokens") or 0
                    cr = usage.get("cache_read_input_tokens") or 0

                    rate = price_for(model)
                    if rate is None:
                        unpriced.add(model)
                        cost = 0.0
                    else:
                        pin, pout, pread = rate
                        if usage.get("speed") == "fast":
                            pin, pout, pread = pin * 2, pout * 2, pread * 2
                        cost = (tin * pin + tout * pout + w5 * pin * 1.25
                                + w1h * pin * 2 + cr * pread) / 1_000_000
                    tok = tin + tout + w5 + w1h + cr

                    cwd = rec.get("cwd")
                    proj = os.path.basename(cwd) if isinstance(cwd, str) and cwd else fallback
                    if proj in ("", "/"):
                        proj = "~"

                    if rate is None:
                        # A project's cost is only meaningful if every model in
                        # it had a rate; otherwise $0.00 would read as "free".
                        unpriced_projects.add(proj)
                    p = projects.setdefault(proj, [0, 0.0, 0])
                    p[0] += tok; p[1] += cost; p[2] += 1
                    m = models.setdefault(model, [0, 0.0, 0])
                    m[0] += tok; m[1] += cost; m[2] += 1
                    total_tok += tok; total_cost += cost; total_msgs += 1

    cx_projects, cx_models, cx_tok, cx_msgs = ({}, {}, 0, 0)
    if os.path.isdir(codex_root):
        cx_projects, cx_models, cx_tok, cx_msgs = scan_codex(codex_root, start)

    gk_projects, gk_models, gk_tok, gk_msgs = ({}, {}, 0, 0)
    if os.path.isdir(grok_root):
        gk_projects, gk_models, gk_tok, gk_msgs = scan_grok(grok_root, start)

    out = sys.stdout

    def emit(kind, name, tok, cost, msgs, priced=1):
        clean = name.replace("\t", " ")
        out.write("%s\t%s\t%d\t%.4f\t%d\t%s\t%d\n"
                  % (kind, clean, tok, cost, msgs, fit(clean), priced))

    emit("TOTAL", "all", total_tok, total_cost, total_msgs,
         0 if unpriced else 1)
    for name, (tok, cost, msgs) in sorted(
            projects.items(), key=lambda kv: kv[1][0], reverse=True)[:5]:
        emit("PROJ", name, tok, cost, msgs, 0 if name in unpriced_projects else 1)
    for name, (tok, cost, msgs) in sorted(
            models.items(), key=lambda kv: kv[1][0], reverse=True)[:5]:
        emit("MODEL", name, tok, cost, msgs, 0 if name in unpriced else 1)
    for name in sorted(unpriced):
        emit("UNPRICED", name, 0, 0.0, 0, 0)

    # Codex publishes no per-token rate for subscription plans at all.
    emit("CODEX_TOTAL", "all", cx_tok, 0.0, cx_msgs, 0)
    for kind, table in (("CODEX_PROJ", cx_projects), ("CODEX_MODEL", cx_models)):
        for name, (tok, cost, msgs) in sorted(
                table.items(), key=lambda kv: kv[1][0], reverse=True)[:5]:
            emit(kind, name, tok, cost, msgs, 0)

    emit("GROK_TOTAL", "all", gk_tok, 0.0, gk_msgs, 0)
    for kind, table in (("GROK_PROJ", gk_projects), ("GROK_MODEL", gk_models)):
        for name, (tok, cost, msgs) in sorted(
                table.items(), key=lambda kv: kv[1][0], reverse=True)[:5]:
            emit(kind, name, tok, cost, msgs, 0)


if __name__ == "__main__":
    main()
