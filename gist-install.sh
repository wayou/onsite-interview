#!/usr/bin/env bash
set -euo pipefail

# Onsite Interview Toolkit — single-file installer
# Install: curl -fsSL https://gist.githubusercontent.com/<user>/<id>/raw/gist-install.sh | bash
#
# This script embeds all toolkit files and extracts them to ~/.onsite-interview/
# then creates a symlink so `eval` is available globally.

INSTALL_DIR="${ONSITE_INTERVIEW_HOME:-$HOME/.onsite-interview}"
BIN_DIR="${ONSITE_INTERVIEW_BIN:-/usr/local/bin}"

echo "Installing onsite-interview toolkit..."
echo "  Target: $INSTALL_DIR"
echo ""

mkdir -p "$INSTALL_DIR"

# ── problem.md ──────────────────────────────────────────────────────────
cat > "$INSTALL_DIR/problem.md" << 'PROBLEM_EOF'
# URL Shortener Service

Build a URL shortener service running on `localhost:8787`.

## API

### Create Short URL

```
POST /shorten
Content-Type: application/json

{"url": "https://example.com"}
```

Returns a JSON response containing a `short_url` field with the shortened URL.

### Redirect

```
GET /:code
```

Redirects to the original URL.

## Requirements

- Use any language or framework
- Service must listen on `http://localhost:8787`
- In-memory storage is fine (no database required)
PROBLEM_EOF

# ── evaluate.sh ─────────────────────────────────────────────────────────
cat > "$INSTALL_DIR/evaluate.sh" << 'EVALUATE_EOF'
@@EVALUATE_SH@@
EVALUATE_EOF

# ── evaluate-ai.sh ──────────────────────────────────────────────────────
cat > "$INSTALL_DIR/evaluate-ai.sh" << 'EVALUATE_AI_EOF'
@@EVALUATE_AI_SH@@
EVALUATE_AI_EOF

# ── eval.sh (entry point) ──────────────────────────────────────────────
cat > "$INSTALL_DIR/eval.sh" << 'EVAL_EOF'
@@EVAL_SH@@
EVAL_EOF

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
