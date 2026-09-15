#!/bin/sh
# The suite lives inside the command itself so it ships with every install.
set -e
exec "$(cd "$(dirname "$0")/.." && pwd)/bin/ai-usage" --self-test
