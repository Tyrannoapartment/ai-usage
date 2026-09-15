<p align="center">
  <img src="assets/tyranno-ai-usage.png" alt="Tyranno holding a usage gauge" width="240">
</p>

# ai-usage

A terminal dashboard for how much of your Claude and Codex quota you have left —
and, for Claude, where it went.

```
┌ AI Usage  10:39:25

 CLAUDE
  5h        ██░░░░░░░░░░░░░░  14.0%  3:40:35
  weekly    █████████░░░░░░░  56.0%  3d 00:20:35
  fable     ████████░░░░░░░░  49.0%  3d 00:20:35
            plan pro   12s ago

 CODEX
  weekly    ████░░░░░░░░░░░░  23.0%  6d 03:49:23
            plan team  reset credits 3

 WHERE (today - 62.1M tok, ~$41.28, 288 msgs; $ estimated)
  api-gateway              █████████░  86.7%    53.8M  $33.43
  web-frontend             █░░░░░░░░░  11.6%     7.2M  $7.00
  infra-scripts            ░░░░░░░░░░   1.4%     882K  $0.59

 WHAT (today - by model)
  claude-opus-5            ████████░░  75.0%    2.56B  $1687.43
  claude-sonnet-5          ██░░░░░░░░  19.7%   672.7M  $175.38
  claude-fable-5-1         ░░░░░░░░░░   4.9%   166.7M  $239.82

 [q] quit  [r] refetch  [d] 7 days  -  api 60s, local 90s
```

The countdowns tick every second. Network calls and transcript scans happen in
the background, so the clock never stalls on them.

## What is real and what is estimated

**The percentages are not estimates.** They come from the same endpoints the
official clients use, authenticated with the OAuth tokens those clients already
stored on your machine:

| Source | Endpoint | Credentials |
| --- | --- | --- |
| Claude | `api.anthropic.com/api/oauth/usage` | macOS login Keychain, falling back to `~/.claude/.credentials.json` |
| Codex | `chatgpt.com/backend-api/wham/usage` | `~/.codex/auth.json` |

Each token is sent only to its own vendor, over HTTPS, and nothing is written
anywhere except a quota cache under `~/.cache/ai-usage/`.

The **WHERE** and **WHAT** sections are aggregated from your local Claude Code
transcripts in `~/.claude/projects/`. Their token counts are exact — they are
read straight out of each message's `usage` record, de-duplicated by message and
request id. **Only the dollar column is an estimate:** subscription plans report
no dollar figures, so tokens are priced at public API rates. Treat it as a
relative signal, not a bill.

## Install

```sh
brew install Tyrannoapartment/tap/ai-usage
```

Without Homebrew — run it once, no install:

```sh
npx @tyrannoapartment/ai-usage
```

Or install from source:

```sh
curl -fsSL https://raw.githubusercontent.com/Tyrannoapartment/ai-usage/main/install.sh | sh
```

That clones into `~/.local/share/ai-usage` and links the command into
`~/.local/bin`. Or clone it yourself and run `./bin/ai-usage` straight from the
checkout — nothing is compiled.

Requires macOS with `jq`, `curl`, `awk`, `python3` and `tput`. Homebrew pulls in
`jq`; the rest ship in `/usr/bin` on a current macOS with the Xcode Command Line
Tools. Runs on stock `/bin/bash` 3.2.

## Usage

```sh
ai-usage                 # live dashboard
ai-usage --days 7        # breakdown over 7 days instead of today
ai-usage --once          # print one frame and exit (pipes, cron, status bars)
ai-usage --json          # raw merged quota JSON
ai-usage --menubar       # one SwiftBar/xbar frame
ai-usage --report        # JSON snapshot (what the menu bar app reads)
ai-usage --self-test     # run the test suite
```

| Key | Action |
| --- | --- |
| `q` | quit |
| `r` | refetch immediately |
| `d` | toggle today / 7 days |

Options: `-i SECONDS` screen redraw (default 1), `--ttl SECONDS` how long a
fetched quota is reused (default 60).

Environment overrides: `AI_USAGE_CLAUDE_CREDS`, `AI_USAGE_CODEX_CREDS`,
`AI_USAGE_CLAUDE_DIR`, `AI_USAGE_CACHE_DIR`, `AI_USAGE_AGG`, `NO_COLOR`.

## Menu bar

Two ways, both optional.

**Native app** — no third-party dependency, countdowns tick every second while
the menu is open, and the status item draws a real gauge:

```sh
./menubar/build.sh --install      # builds AIUsage.app into /Applications
open /Applications/AIUsage.app
```

It compiles one Swift file with `swiftc`; no Xcode project, no App Store, and
nothing to notarize because the binary never leaves the machine that built it.
Add it to System Settings → General → Login Items to have it start with the Mac.

**SwiftBar plugin** — if you already run SwiftBar or xbar:

```sh
brew install --cask swiftbar
ln -s "$(brew --prefix)/share/ai-usage/ai-usage.30s.sh" ~/SwiftBar/ai-usage.30s.sh
```

Either way the title shows whichever limit is closest to its ceiling — one
number, coloured on the same ramp, so a glance tells you whether anything needs
attention. The dropdown carries every limit with its countdown and today's
busiest sessions.

`ai-usage --menubar` prints a SwiftBar/xbar frame and `ai-usage --report` prints
a JSON snapshot, which is what the app consumes; neither re-implements any of
the parsing or pricing.

## Colors

Percentages run along a seven-stop ramp from green to red, and each bar is
coloured cell by cell, so a bar gets hotter as it fills rather than flipping
between three states. Terminals without 256-color support fall back to three
steps; `NO_COLOR` or a non-TTY drops color entirely.

## Known limits

- **Over SSH, the Claude section will not work.** Claude Code keeps its
  credentials in the macOS login Keychain, which a non-interactive SSH session
  cannot unlock. The dashboard says so explicitly rather than showing a blank.
  Run it on the machine itself, or unlock the keychain first with
  `security unlock-keychain ~/Library/Keychains/login.keychain-db`. Codex stores
  its token in a plain file, so the Codex section works fine over SSH.
- **The endpoints are undocumented.** They are what the official clients call,
  not a published API, and either vendor can change the response shape. When
  that happens a section renders as "no active limits reported"; `--json` shows
  the raw payload so you can see what moved.
- **Codex reports whichever windows it wants.** Right now that is often a single
  weekly window. A 5-hour window renders automatically if the server starts
  sending one.
- **The breakdown is per-machine.** Quota is account-wide, but WHERE and WHAT
  only cover work done on this machine.

## Tests

```sh
./test/run-tests.sh
```

Thirty-one checks over fixtures, no network: quota parsing for both vendors,
credential-source selection (Keychain vs. file, newest token wins), failure
hints, token aggregation and de-duplication, pricing, and the display helpers.

## License

MIT
