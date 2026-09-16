<p align="center">
  <img src="assets/tyranno-ai-usage.png" alt="Tyranno holding a usage gauge" width="240">
</p>

# ai-usage

A terminal dashboard for how much of your Claude and Codex quota you have left —
and, for Claude, where it went.

```
┌ AI Usage  14:24:04

 LIMITS
   claude 5h       ░░░░░░░░░░░░   0.0%  4:55:56
   claude weekly   ██████████░░  81.0%  1d 20:35:56
   claude fable    ██████░░░░░░  54.0%  1d 20:35:56
          pro  1m ago
   codex  weekly   █████░░░░░░░  41.0%  5d 00:04:44
          plan team  reset credits 3  22s ago

 USAGE · today
   claude (366.1M tok  ~$257.12  836 msgs)
     by project
       api-gateway               45.7%   167.4M  $105.84
       web-frontend              42.8%   156.7M  $105.91
     by model
       claude-opus-5             98.9%   362.0M  $248.01
   codex (33.0M tok  292 msgs  no published rate)
     by project
       api-gateway              100.0%    33.0M

 [q] quit  [r] refetch  [d] 7 days  [c] limits only
```

The countdowns tick every second. Network calls and transcript scans happen in
the background, so the clock never stalls on them. In a window too short for the
whole frame the quota stays put and the breakdown is what gets cut; the frame
follows the window as you resize it.

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

The **WHERE** and **WHAT** sections are aggregated from local transcripts —
`~/.claude/projects/` for Claude, `~/.codex/sessions/` for Codex. Their token
counts are exact: read straight out of each turn's usage record, de-duplicated
by message and request id.

**Only the dollar column is an estimate**, and it is conservative. Subscription
plans report no dollar figures, so Claude tokens are priced at public API rates.
A model with no published rate contributes its tokens but no cost and is marked
`no published rate`, which makes the total a floor rather than a guess — the
tool will not invent a price for a model it does not know. Codex publishes no
per-token rate for subscription plans at all, so its rows carry tokens only.

If an endpoint answers `429`, the tool says so and stops calling it for five
minutes rather than hammering through a rate limit.

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
ai-usage --compact       # limits only, no breakdown
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
| `c` | toggle compact (limits only) |

Options: `-i SECONDS` screen redraw (default 1), `--ttl SECONDS` how long a
fetched quota is reused (default 60).

Environment overrides: `AI_USAGE_CLAUDE_CREDS`, `AI_USAGE_CODEX_CREDS`,
`AI_USAGE_CLAUDE_DIR`, `AI_USAGE_CACHE_DIR`, `AI_USAGE_AGG`, `NO_COLOR`.

## Menu bar

Two ways, both optional.

**Native app** — no third-party dependency, countdowns tick every second while
the menu is open, and the status item draws a real gauge:

```sh
brew install --cask Tyrannoapartment/tap/ai-usage-app
```

Signed with a Developer ID and notarized by Apple, so it opens without a
Gatekeeper prompt. To build it yourself instead — one Swift file, `swiftc`, no
Xcode project:

```sh
./menubar/build.sh --install      # builds AIUsage.app into /Applications
```

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

## Several accounts

People who keep more than one Claude or Codex login — each in its own config
directory, the way `CLAUDE_CONFIG_DIR` and `CODEX_HOME` work — can list them in
`~/.config/ai-usage/accounts.json`:

```json
{
  "accounts": [
    { "claude": "~/.claude", "codex": "~/.codex" },
    { "label": "work", "codex": "~/.codex-work" },
    { "label": "side", "claude": "~/.claude-side" }
  ]
}
```

Each entry may carry `claude`, `codex`, or both. Labels are optional: Codex is
named by the signed-in email its API reports, Claude by its plan. With no file,
the standard pair is the only account and nothing on screen changes.

One caveat: the macOS Keychain holds exactly one Claude Code credential, so only
the default `~/.claude` account reads it. Other accounts use the
`.credentials.json` inside their own directory, which Claude Code may not
refresh — if one goes stale, run `claude` once with `CLAUDE_CONFIG_DIR` pointed
at it.

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
- **Only a Team plan has been exercised end to end.** Other plans return limit
  kinds this build has never seen (`seven_day_opus`, `seven_day_oauth_apps`, …).
  They render — the names are shortened to fit the column — but the wording is
  whatever the API sends.
- **Codex reports whichever windows it wants.** Right now that is often a single
  weekly window. A 5-hour window renders automatically if the server starts
  sending one.
- **The breakdown is per-machine.** Quota is account-wide, but WHERE and WHAT
  only cover work done on this machine.

## Tests

```sh
./test/run-tests.sh
```

59 checks over fixtures, no network: quota parsing for both vendors,
credential-source selection (Keychain vs. file, newest token wins), failure
hints, token aggregation and de-duplication, pricing, and the display helpers.

## License

MIT
