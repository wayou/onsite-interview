#!/usr/bin/env bash
set -euo pipefail

# Onsite Interview Toolkit — remote installer
# Usage: curl -fsSL https://raw.githubusercontent.com/wayou/onsite-interview/master/install.sh | bash

REPO="https://raw.githubusercontent.com/wayou/onsite-interview/master"
INSTALL_DIR="${ONSITE_INTERVIEW_HOME:-$HOME/.onsite-interview}"
BIN_DIR="${ONSITE_INTERVIEW_BIN:-/usr/local/bin}"

FILES="eval.sh evaluate.sh evaluate-ai.sh evaluate-ai-llm.sh problem.md README.md"

echo "Installing onsite-interview toolkit..."
echo "  Target: $INSTALL_DIR"
echo ""

mkdir -p "$INSTALL_DIR"

for f in $FILES; do
  echo "  Downloading $f..."
  curl -fsSL "$REPO/$f" -o "$INSTALL_DIR/$f"
done

chmod +x "$INSTALL_DIR/eval.sh" "$INSTALL_DIR/evaluate.sh" "$INSTALL_DIR/evaluate-ai.sh" "$INSTALL_DIR/evaluate-ai-llm.sh"

# ── Symlink ─────────────────────────────────────────────────────────────
# Ensure BIN_DIR exists (some systems lack /usr/local/bin by default)
if [[ ! -d "$BIN_DIR" ]]; then
  sudo mkdir -p "$BIN_DIR"
fi

if [[ -w "$BIN_DIR" ]]; then
  ln -sf "$INSTALL_DIR/eval.sh" "$BIN_DIR/assess"
else
  echo "  Cannot write to $BIN_DIR — trying with sudo..."
  sudo ln -sf "$INSTALL_DIR/eval.sh" "$BIN_DIR/assess"
fi

# ── Print version ────────────────────────────────────────────────────────
INSTALLED_VERSION=$(grep -m1 '^VERSION=' "$INSTALL_DIR/eval.sh" | cut -d'"' -f2)

echo ""
echo "Done! Installed: assess v${INSTALLED_VERSION} → $BIN_DIR/assess"
echo ""
echo "Usage:"
echo "  assess                    # run both evaluations"
echo "  assess setup              # copy problem.md to start an interview"
echo "  assess cleanup            # clean up after interview"
echo "  assess update             # update to latest version"
echo "  assess update --force     # force re-download all files"
echo "  assess -f                 # functional only"
echo "  assess -a -s file.jsonl   # AI collaboration only"
echo ""
echo "To uninstall: rm -rf $INSTALL_DIR && rm -f $BIN_DIR/assess"
