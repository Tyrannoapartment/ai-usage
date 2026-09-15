#!/usr/bin/env python3
"""Aggregate local Claude Code transcripts: where and on what the tokens went.

Token counts are exact (read straight out of each message's usage record).
Dollar figures are an estimate: token counts priced at public API rates.

Emits TSV:  KIND \t name \t tokens \t cost \t messages \t padded-name

The padded name is pre-fitted to a fixed number of terminal columns, counting
East Asian wide characters as two, so the caller can print it verbatim.
"""
import json, os, sys, time, unicodedata

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
DEFAULT_PRICE = (5.0, 25.0, 0.50)


def price_for(model):
    for prefix, pin, pout, pread in PRICES:
        if model.startswith(prefix):
            return pin, pout, pread
    return DEFAULT_PRICE


def main():
    root = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/.claude/projects")
    days = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0

    now = time.time()
    if days <= 1:
        lt = time.localtime(now)
        start = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))
    else:
        start = now - days * 86400
    file_cutoff = start - 86400  # mtime is the last write, so keep a day of slack

    seen = set()
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
                    try:
                        epoch = time.mktime(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S")) - time.timezone
                    except Exception:
                        continue
                    if epoch < start:
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

                    pin, pout, pread = price_for(model)
                    if usage.get("speed") == "fast":
                        pin, pout, pread = pin * 2, pout * 2, pread * 2
                    cost = (tin * pin + tout * pout + w5 * pin * 1.25
                            + w1h * pin * 2 + cr * pread) / 1_000_000
                    tok = tin + tout + w5 + w1h + cr

                    cwd = rec.get("cwd")
                    proj = os.path.basename(cwd) if isinstance(cwd, str) and cwd else fallback
                    if proj in ("", "/"):
                        proj = "~"

                    p = projects.setdefault(proj, [0, 0.0, 0])
                    p[0] += tok; p[1] += cost; p[2] += 1
                    m = models.setdefault(model, [0, 0.0, 0])
                    m[0] += tok; m[1] += cost; m[2] += 1
                    total_tok += tok; total_cost += cost; total_msgs += 1

    out = sys.stdout
    out.write("TOTAL\tall\t%d\t%.4f\t%d\t%s\n" % (total_tok, total_cost, total_msgs, fit("all")))
    for kind, table in (("PROJ", projects), ("MODEL", models)):
        rows = sorted(table.items(), key=lambda kv: kv[1][0], reverse=True)[:5]
        for name, (tok, cost, msgs) in rows:
            clean = name.replace("\t", " ")
            out.write("%s\t%s\t%d\t%.4f\t%d\t%s\n" % (kind, clean, tok, cost, msgs, fit(clean)))


if __name__ == "__main__":
    main()
