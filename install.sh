#!/bin/sh
# Symlink the ai-usage command onto PATH.
set -e

ROOT=$(cd "$(dirname "$0")" && pwd)
BIN=${BIN_DIR:-$HOME/.local/bin}

mkdir -p "$BIN"
ln -sf "$ROOT/bin/ai-usage" "$BIN/ai-usage"
echo "linked $BIN/ai-usage -> $ROOT/bin/ai-usage"

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "note: $BIN is not on your PATH; add it in your shell profile" ;;
esac

"$BIN/ai-usage" --self-test >/dev/null 2>&1 \
  && echo "self-test passed" \
  || echo "self-test FAILED - run '$BIN/ai-usage --self-test' to see why"
