#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${1:-/usr/local/bin}"

ln -sf "$REPO_DIR/eval.sh" "$BIN_DIR/eval"

echo "Installed: eval → $BIN_DIR/eval"
echo "Usage: cd /path/to/candidate/session && eval"
