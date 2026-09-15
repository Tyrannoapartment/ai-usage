#!/bin/bash
#
# SwiftBar / xbar plugin for ai-usage.
#
# <xbar.title>AI Usage</xbar.title>
# <xbar.version>v0.2.0</xbar.version>
# <xbar.author>TyrannoApartment</xbar.author>
# <xbar.desc>Claude and Codex quota in the menu bar.</xbar.desc>
# <xbar.dependencies>ai-usage</xbar.dependencies>
# <xbar.abouturl>https://github.com/Tyrannoapartment/ai-usage</xbar.abouturl>
#
# Install:
#   brew install --cask swiftbar
#   ln -s "$(brew --prefix)/share/ai-usage/ai-usage.30s.sh" ~/SwiftBar/ai-usage.30s.sh
#
# The filename sets the refresh interval; rename to .1m.sh, .5m.sh and so on to
# poll less often. ai-usage caches quota for 60s regardless, so a faster plugin
# interval mostly just re-renders the same numbers.

# SwiftBar starts with a minimal PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

if ! command -v ai-usage >/dev/null 2>&1; then
  echo "● ai-usage | color=#f85149"
  echo "---"
  echo "ai-usage is not on PATH"
  echo "Install | href=https://github.com/Tyrannoapartment/ai-usage"
  exit 0
fi

exec ai-usage --menubar
