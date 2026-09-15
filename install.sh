#!/bin/sh
# Install ai-usage.
#
#   ./install.sh                      from a checkout: link it onto PATH
#   curl -fsSL <raw-url> | sh         no checkout: clone, then link
#
# Override the destinations with BIN_DIR and SRC_DIR.
set -e

REPO=https://github.com/Tyrannoapartment/ai-usage.git
BIN=${BIN_DIR:-$HOME/.local/bin}
SRC=${SRC_DIR:-$HOME/.local/share/ai-usage}

# When curled, $0 is "sh" and names no real file, so fall back to cloning.
# Testing only for ./bin/ai-usage would wrongly pick up whatever checkout the
# user happens to be standing in.
ROOT=""
if [ -f "$0" ] && [ -f "$(dirname "$0")/bin/ai-usage" ]; then
  ROOT=$(cd "$(dirname "$0")" && pwd)
fi

if [ -z "$ROOT" ]; then
  command -v git >/dev/null 2>&1 || { echo "ai-usage: git is required" >&2; exit 1; }
  if [ -d "$SRC/.git" ]; then
    echo "updating $SRC"
    git -C "$SRC" pull --quiet --ff-only
  else
    echo "cloning into $SRC"
    mkdir -p "$(dirname "$SRC")"
    git clone --quiet --depth 1 "$REPO" "$SRC"
  fi
  ROOT=$SRC
fi

mkdir -p "$BIN"
ln -sf "$ROOT/bin/ai-usage" "$BIN/ai-usage"
echo "linked $BIN/ai-usage -> $ROOT/bin/ai-usage"

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "note: $BIN is not on your PATH; add it in your shell profile" ;;
esac

if "$BIN/ai-usage" --self-test >/dev/null 2>&1; then
  echo "self-test passed - run: ai-usage"
else
  echo "self-test FAILED - run '$BIN/ai-usage --self-test' to see why" >&2
  exit 1
fi
