#!/usr/bin/env bash
set -euo pipefail

# Build the self-contained gist installer by embedding all script files.
# Output: gist-install.sh (ready to upload to GitHub Gist)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$SCRIPT_DIR/gist-install.sh"

# Read the template (gist-install.sh itself, but we rebuild from scratch)
HEADER='#!/usr/bin/env bash
set -euo pipefail

# Onsite Interview Toolkit — single-file installer
# Install: curl -fsSL <gist-raw-url> | bash
#
# This script embeds all toolkit files and extracts them to ~/.onsite-interview/
# then creates a symlink so `eval` is available globally.

INSTALL_DIR="${ONSITE_INTERVIEW_HOME:-$HOME/.onsite-interview}"
BIN_DIR="${ONSITE_INTERVIEW_BIN:-/usr/local/bin}"

echo "Installing onsite-interview toolkit..."
echo "  Target: $INSTALL_DIR"
echo ""

mkdir -p "$INSTALL_DIR"'

# Use a unique delimiter that won't appear in any script
emit_file() {
  local varname="$1" filepath="$2" delim="$3"
  echo ""
  echo "cat > \"\$INSTALL_DIR/$varname\" << '${delim}'"
  cat "$filepath"
  echo "${delim}"
}

{
  echo "$HEADER"
  emit_file "problem.md"     "$SCRIPT_DIR/problem.md"     "PROBLEM_HEREDOC_EOF"
  emit_file "evaluate.sh"    "$SCRIPT_DIR/evaluate.sh"    "EVALUATE_HEREDOC_EOF"
  emit_file "evaluate-ai.sh" "$SCRIPT_DIR/evaluate-ai.sh" "EVALUATE_AI_HEREDOC_EOF"
  emit_file "eval.sh"        "$SCRIPT_DIR/eval.sh"        "EVAL_HEREDOC_EOF"

  cat << 'FOOTER'

chmod +x "$INSTALL_DIR/evaluate.sh" "$INSTALL_DIR/evaluate-ai.sh" "$INSTALL_DIR/eval.sh"

# ── Symlink ─────────────────────────────────────────────────────────────
# Ensure BIN_DIR exists (some systems lack /usr/local/bin by default)
if [[ ! -d "$BIN_DIR" ]]; then
  sudo mkdir -p "$BIN_DIR"
fi

if [[ -w "$BIN_DIR" ]]; then
  ln -sf "$INSTALL_DIR/eval.sh" "$BIN_DIR/eval"
  echo "Installed: eval → $BIN_DIR/eval"
else
  echo "Cannot write to $BIN_DIR — trying with sudo..."
  sudo ln -sf "$INSTALL_DIR/eval.sh" "$BIN_DIR/eval"
  echo "Installed: eval → $BIN_DIR/eval"
fi

echo ""
echo "Done! Usage:"
echo "  eval                    # run both evaluations"
echo "  eval -f                 # functional only"
echo "  eval -a -s file.jsonl   # AI collaboration only"
echo "  cat ~/.onsite-interview/problem.md  # view the problem"
echo ""
echo "To uninstall: rm -rf ~/.onsite-interview && rm -f $BIN_DIR/eval"
FOOTER
} > "$OUT"

chmod +x "$OUT"
echo "Built: $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
