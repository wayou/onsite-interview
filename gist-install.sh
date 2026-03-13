#!/usr/bin/env bash
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

mkdir -p "$INSTALL_DIR"

cat > "$INSTALL_DIR/problem.md" << 'PROBLEM_HEREDOC_EOF'
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
PROBLEM_HEREDOC_EOF

cat > "$INSTALL_DIR/evaluate.sh" << 'EVALUATE_HEREDOC_EOF'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-http://localhost:8787}"
TOTAL=0
PASS=0
FAIL=0
SCORE=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_pass() {
  local pts=$1 desc=$2
  SCORE=$((SCORE + pts))
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
  echo -e "  ${GREEN}✓${NC} [+${pts}] ${desc}"
}

log_fail() {
  local pts=$1 desc=$2 reason=${3:-}
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
  if [[ -n "$reason" ]]; then
    echo -e "  ${RED}✗${NC} [+0/${pts}] ${desc} — ${reason}"
  else
    echo -e "  ${RED}✗${NC} [+0/${pts}] ${desc}"
  fi
}

# ── Phase 1: Basic Functionality (40 pts) ──────────────────────────────

echo -e "\n${BOLD}${BLUE}Phase 1: Basic Functionality (40 pts)${NC}"

# Test 1: POST /shorten creates short URL (8 pts)
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/shorten" \
  -H "Content-Type: application/json" \
  -d '{"url": "https://example.com"}' 2>/dev/null || echo -e "\n000")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

if [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
  log_pass 8 "POST /shorten returns 2xx ($HTTP_CODE)"
else
  log_fail 8 "POST /shorten returns 2xx" "got $HTTP_CODE"
fi

# Test 2: Response contains short_url field (4 pts)
SHORT_URL=$(echo "$BODY" | jq -r '.short_url // empty' 2>/dev/null || true)
if [[ -n "$SHORT_URL" ]]; then
  log_pass 4 "Response contains short_url field"
else
  log_fail 4 "Response contains short_url field" "field missing or not valid JSON"
fi

# Extract short code from short_url
SHORT_CODE=""
if [[ -n "$SHORT_URL" ]]; then
  SHORT_CODE=$(echo "$SHORT_URL" | grep -oE '[^/]+$' || true)
fi

# Test 3: GET /:code redirects with correct Location (8 pts)
if [[ -n "$SHORT_CODE" ]]; then
  REDIR_RESP=$(curl -s -o /dev/null -w "%{http_code}\n%{redirect_url}" \
    "$BASE_URL/$SHORT_CODE" 2>/dev/null || echo "000")
  REDIR_CODE=$(echo "$REDIR_RESP" | head -1)
  REDIR_LOC=$(echo "$REDIR_RESP" | tail -1)

  if [[ "$REDIR_CODE" =~ ^3[0-9][0-9]$ ]] && [[ "$REDIR_LOC" == "https://example.com" || "$REDIR_LOC" == "https://example.com/" ]]; then
    log_pass 8 "GET /:code redirects (${REDIR_CODE}) with correct Location"
  elif [[ "$REDIR_CODE" =~ ^3[0-9][0-9]$ ]]; then
    log_fail 8 "GET /:code redirects with correct Location" "status $REDIR_CODE but Location='$REDIR_LOC'"
  else
    log_fail 8 "GET /:code redirects with correct Location" "got status $REDIR_CODE"
  fi
else
  log_fail 8 "GET /:code redirects with correct Location" "no short code to test"
fi

# Test 4: Follow redirect end-to-end (4 pts)
if [[ -n "$SHORT_CODE" ]]; then
  FINAL_URL=$(curl -s -o /dev/null -w "%{url_effective}" -L "$BASE_URL/$SHORT_CODE" 2>/dev/null || true)
  if [[ "$FINAL_URL" == "https://example.com" || "$FINAL_URL" == "https://example.com/" ]]; then
    log_pass 4 "Follow redirect reaches original URL"
  else
    log_fail 4 "Follow redirect reaches original URL" "ended at '$FINAL_URL'"
  fi
else
  log_fail 4 "Follow redirect reaches original URL" "no short code to test"
fi

# Test 5: Second URL gets different short code (5 pts)
RESP2=$(curl -s -X POST "$BASE_URL/shorten" \
  -H "Content-Type: application/json" \
  -d '{"url": "https://github.com"}' 2>/dev/null || true)
SHORT_URL2=$(echo "$RESP2" | jq -r '.short_url // empty' 2>/dev/null || true)
SHORT_CODE2=""
if [[ -n "$SHORT_URL2" ]]; then
  SHORT_CODE2=$(echo "$SHORT_URL2" | grep -oE '[^/]+$' || true)
fi

if [[ -n "$SHORT_CODE2" ]] && [[ "$SHORT_CODE2" != "$SHORT_CODE" ]]; then
  log_pass 5 "Second URL gets different short code"
elif [[ -z "$SHORT_CODE2" ]]; then
  log_fail 5 "Second URL gets different short code" "second shorten failed"
else
  log_fail 5 "Second URL gets different short code" "same code '$SHORT_CODE' returned"
fi

# Test 6: First short code still works (5 pts)
if [[ -n "$SHORT_CODE" ]]; then
  RECHECK=$(curl -s -o /dev/null -w "%{redirect_url}" "$BASE_URL/$SHORT_CODE" 2>/dev/null || true)
  if [[ "$RECHECK" == "https://example.com" || "$RECHECK" == "https://example.com/" ]]; then
    log_pass 5 "First short code still works after creating second"
  else
    log_fail 5 "First short code still works after creating second" "redirects to '$RECHECK'"
  fi
else
  log_fail 5 "First short code still works after creating second" "no short code"
fi

# Test 7: URL with path + query params preserved (6 pts)
COMPLEX_URL="https://example.com/path/to/page?foo=bar&baz=qux#section"
RESP3=$(curl -s -X POST "$BASE_URL/shorten" \
  -H "Content-Type: application/json" \
  -d "{\"url\": \"$COMPLEX_URL\"}" 2>/dev/null || true)
SHORT_URL3=$(echo "$RESP3" | jq -r '.short_url // empty' 2>/dev/null || true)
SHORT_CODE3=""
if [[ -n "$SHORT_URL3" ]]; then
  SHORT_CODE3=$(echo "$SHORT_URL3" | grep -oE '[^/]+$' || true)
fi

if [[ -n "$SHORT_CODE3" ]]; then
  COMPLEX_LOC=$(curl -s -o /dev/null -w "%{redirect_url}" "$BASE_URL/$SHORT_CODE3" 2>/dev/null || true)
  if [[ "$COMPLEX_LOC" == "$COMPLEX_URL" ]]; then
    log_pass 6 "URL with path + query params preserved"
  else
    log_fail 6 "URL with path + query params preserved" "got '$COMPLEX_LOC'"
  fi
else
  log_fail 6 "URL with path + query params preserved" "shorten failed"
fi

# ── Phase 2: Input Validation (20 pts) ─────────────────────────────────

echo -e "\n${BOLD}${BLUE}Phase 2: Input Validation (20 pts)${NC}"

# Test: Invalid URL string → 4xx (4 pts)
INV_RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/shorten" \
  -H "Content-Type: application/json" \
  -d '{"url": "not-a-valid-url"}' 2>/dev/null || echo "000")
if [[ "$INV_RESP" =~ ^4[0-9][0-9]$ ]]; then
  log_pass 4 "Invalid URL string → 4xx ($INV_RESP)"
else
  log_fail 4 "Invalid URL string → 4xx" "got $INV_RESP"
fi

# Test: Empty body → 4xx (4 pts)
EMPTY_RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/shorten" \
  -H "Content-Type: application/json" \
  -d '' 2>/dev/null || echo "000")
if [[ "$EMPTY_RESP" =~ ^4[0-9][0-9]$ ]]; then
  log_pass 4 "Empty body → 4xx ($EMPTY_RESP)"
else
  log_fail 4 "Empty body → 4xx" "got $EMPTY_RESP"
fi

# Test: Missing url field → 4xx (4 pts)
MISS_RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/shorten" \
  -H "Content-Type: application/json" \
  -d '{"link": "https://example.com"}' 2>/dev/null || echo "000")
if [[ "$MISS_RESP" =~ ^4[0-9][0-9]$ ]]; then
  log_pass 4 "Missing url field → 4xx ($MISS_RESP)"
else
  log_fail 4 "Missing url field → 4xx" "got $MISS_RESP"
fi

# Test: Non-existent short code → 404 (4 pts)
NF_RESP=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/zzznonexistent999" 2>/dev/null || echo "000")
if [[ "$NF_RESP" == "404" ]]; then
  log_pass 4 "Non-existent short code → 404"
else
  log_fail 4 "Non-existent short code → 404" "got $NF_RESP"
fi

# Test: Very long URL handled gracefully (4 pts)
LONG_URL="https://example.com/$(head -c 2000 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 2000)"
LONG_RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/shorten" \
  -H "Content-Type: application/json" \
  -d "{\"url\": \"$LONG_URL\"}" 2>/dev/null || echo "000")
if [[ "$LONG_RESP" =~ ^[2-4][0-9][0-9]$ ]]; then
  log_pass 4 "Very long URL (2000+ chars) handled gracefully ($LONG_RESP)"
else
  log_fail 4 "Very long URL (2000+ chars) handled gracefully" "got $LONG_RESP"
fi

# ── Phase 3: Security (20 pts) ─────────────────────────────────────────

echo -e "\n${BOLD}${BLUE}Phase 3: Security (20 pts)${NC}"

# Test: javascript: URL rejected (5 pts)
JS_RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/shorten" \
  -H "Content-Type: application/json" \
  -d '{"url": "javascript:alert(1)"}' 2>/dev/null || echo "000")
if [[ "$JS_RESP" =~ ^4[0-9][0-9]$ ]]; then
  log_pass 5 "javascript:alert(1) rejected ($JS_RESP)"
else
  log_fail 5 "javascript:alert(1) rejected" "got $JS_RESP"
fi

# Test: data: URL rejected (4 pts)
DATA_RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/shorten" \
  -H "Content-Type: application/json" \
  -d '{"url": "data:text/html,<script>alert(1)</script>"}' 2>/dev/null || echo "000")
if [[ "$DATA_RESP" =~ ^4[0-9][0-9]$ ]]; then
  log_pass 4 "data:text/html URL rejected ($DATA_RESP)"
else
  log_fail 4 "data:text/html URL rejected" "got $DATA_RESP"
fi

# Test: SQL injection in GET → not 500 (5 pts)
SQLI_RESP=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/'; DROP TABLE urls;--" 2>/dev/null || echo "000")
if [[ "$SQLI_RESP" != "500" ]] && [[ "$SQLI_RESP" != "000" ]]; then
  log_pass 5 "SQL injection in GET → not 500 (got $SQLI_RESP)"
else
  log_fail 5 "SQL injection in GET → not 500" "got $SQLI_RESP"
fi

# Test: XSS payload as URL → rejected (4 pts)
XSS_RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/shorten" \
  -H "Content-Type: application/json" \
  -d '{"url": "<script>alert(document.cookie)</script>"}' 2>/dev/null || echo "000")
if [[ "$XSS_RESP" =~ ^4[0-9][0-9]$ ]]; then
  log_pass 4 "XSS payload as URL → rejected ($XSS_RESP)"
else
  log_fail 4 "XSS payload as URL → rejected" "got $XSS_RESP"
fi

# Test: Errors don't leak internals (2 pts)
ERR_BODY=$(curl -s -X POST "$BASE_URL/shorten" \
  -H "Content-Type: application/json" \
  -d '{"url": "not-valid"}' 2>/dev/null || true)
# Check for common leak patterns: stack traces, file paths, SQL
if echo "$ERR_BODY" | grep -qiE '(stack trace|\.go:|\.js:|\.py:|\.java:|node_modules|/home/|/usr/|SELECT |INSERT |at .+ \()'; then
  log_fail 2 "Errors don't leak internals" "found stack trace or internal paths"
else
  log_pass 2 "Errors don't leak internals"
fi

# ── Phase 4: HTTP & Robustness (20 pts) ────────────────────────────────

echo -e "\n${BOLD}${BLUE}Phase 4: HTTP & Robustness (20 pts)${NC}"

# Test: Create returns 201 (3 pts)
CREATE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/shorten" \
  -H "Content-Type: application/json" \
  -d '{"url": "https://httpbin.org/get"}' 2>/dev/null || echo "000")
if [[ "$CREATE_CODE" == "201" ]]; then
  log_pass 3 "Create returns 201"
else
  log_fail 3 "Create returns 201" "got $CREATE_CODE"
fi

# Test: Response Content-Type is application/json (3 pts)
CT_RESP=$(curl -s -o /dev/null -w "%{content_type}" -X POST "$BASE_URL/shorten" \
  -H "Content-Type: application/json" \
  -d '{"url": "https://httpbin.org/json"}' 2>/dev/null || true)
if echo "$CT_RESP" | grep -qi 'application/json'; then
  log_pass 3 "Response Content-Type is application/json"
else
  log_fail 3 "Response Content-Type is application/json" "got '$CT_RESP'"
fi

# Test: Redirect uses 301 or 302 (3 pts)
if [[ -n "$SHORT_CODE" ]]; then
  REDIR_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/$SHORT_CODE" 2>/dev/null || echo "000")
  if [[ "$REDIR_STATUS" == "301" ]] || [[ "$REDIR_STATUS" == "302" ]]; then
    log_pass 3 "Redirect uses 301 or 302 ($REDIR_STATUS)"
  else
    log_fail 3 "Redirect uses 301 or 302" "got $REDIR_STATUS"
  fi
else
  log_fail 3 "Redirect uses 301 or 302" "no short code to test"
fi

# Test: 404 for not-found (3 pts)
NF2_RESP=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/absolutelynotfound" 2>/dev/null || echo "000")
if [[ "$NF2_RESP" == "404" ]]; then
  log_pass 3 "404 for not-found code"
else
  log_fail 3 "404 for not-found code" "got $NF2_RESP"
fi

# Test: Response time < 2s (2 pts)
TIME_TOTAL=$(curl -s -o /dev/null -w "%{time_total}" -X POST "$BASE_URL/shorten" \
  -H "Content-Type: application/json" \
  -d '{"url": "https://example.com/speed-test"}' 2>/dev/null || echo "99")
TIME_MS=$(echo "$TIME_TOTAL" | awk '{printf "%d", $1 * 1000}')
if [[ "$TIME_MS" -lt 2000 ]]; then
  log_pass 2 "Response time < 2s (${TIME_MS}ms)"
else
  log_fail 2 "Response time < 2s" "${TIME_MS}ms"
fi

# Test: 5 concurrent requests all succeed (4 pts)
CONC_OK=0
CONC_PIDS=()
CONC_TMPDIR=$(mktemp -d)
for i in $(seq 1 5); do
  curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/shorten" \
    -H "Content-Type: application/json" \
    -d "{\"url\": \"https://example.com/concurrent/$i\"}" \
    > "$CONC_TMPDIR/$i" 2>/dev/null &
  CONC_PIDS+=($!)
done
for pid in "${CONC_PIDS[@]}"; do
  wait "$pid" 2>/dev/null || true
done
for i in $(seq 1 5); do
  code=$(cat "$CONC_TMPDIR/$i" 2>/dev/null || echo "000")
  if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    CONC_OK=$((CONC_OK + 1))
  fi
done
rm -rf "$CONC_TMPDIR"
if [[ "$CONC_OK" -eq 5 ]]; then
  log_pass 4 "5 concurrent requests all succeed"
else
  log_fail 4 "5 concurrent requests all succeed" "$CONC_OK/5 succeeded"
fi

# Test: Duplicate URL handled (2 pts)
DUP1=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/shorten" \
  -H "Content-Type: application/json" \
  -d '{"url": "https://duplicate-test.com"}' 2>/dev/null || echo "000")
DUP2=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/shorten" \
  -H "Content-Type: application/json" \
  -d '{"url": "https://duplicate-test.com"}' 2>/dev/null || echo "000")
if [[ "$DUP1" =~ ^2[0-9][0-9]$ ]] && [[ "$DUP2" =~ ^2[0-9][0-9]$ ]]; then
  log_pass 2 "Duplicate URL handled without crashing"
else
  log_fail 2 "Duplicate URL handled without crashing" "responses: $DUP1, $DUP2"
fi

# ── Summary ─────────────────────────────────────────────────────────────

echo -e "\n${BOLD}════════════════════════════════════════${NC}"
echo -e "${BOLD}  Results: ${GREEN}${PASS} passed${NC} / ${RED}${FAIL} failed${NC} (${TOTAL} tests)"
echo -e "${BOLD}  Score:   ${SCORE} / 100${NC}"

if [[ $SCORE -ge 90 ]]; then
  GRADE="A"; COLOR="$GREEN"; INTERP="Exceptional — strong engineering + AI skills"
elif [[ $SCORE -ge 75 ]]; then
  GRADE="B"; COLOR="$GREEN"; INTERP="Good — solid fundamentals, good AI collaboration"
elif [[ $SCORE -ge 60 ]]; then
  GRADE="C"; COLOR="$YELLOW"; INTERP="Acceptable — basics work, missed quality aspects"
elif [[ $SCORE -ge 40 ]]; then
  GRADE="D"; COLOR="$RED"; INTERP="Below bar — only basic functionality"
else
  GRADE="F"; COLOR="$RED"; INTERP="Failing — couldn't get basics working"
fi

echo -e "${BOLD}  Grade:   ${COLOR}${GRADE}${NC} — ${INTERP}"
echo -e "${BOLD}════════════════════════════════════════${NC}\n"

exit 0
EVALUATE_HEREDOC_EOF

cat > "$INSTALL_DIR/evaluate-ai-llm.sh" << 'EVALUATE_AI_LLM_HEREDOC_EOF'
#!/usr/bin/env bash
set -euo pipefail

# ── Preflight ────────────────────────────────────────────────────────
if ! command -v claude &>/dev/null; then
  echo "Error: 'claude' CLI not found. Install Claude Code first." >&2
  echo "  https://docs.anthropic.com/en/docs/claude-code" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "Error: 'jq' not found. Install jq first." >&2
  exit 1
fi

# ── Model selection ──────────────────────────────────────────────────
MODEL="sonnet"

# Pre-scan for --model flag before session discovery consumes args
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    *)       ARGS+=("$1"); shift ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

# ── Session Discovery (reused from evaluate-ai.sh) ──────────────────
SESSION_FILE=""

resolve_session_file() {
  local workdir="${1:-$(pwd)}"
  workdir="$(cd "$workdir" && pwd)"

  local project_dir="$HOME/.claude/projects/$(echo "${workdir}" | sed 's|/|-|g')"

  if [[ ! -d "$project_dir" ]]; then
    echo "Error: No Claude Code project found at $project_dir" >&2
    exit 1
  fi

  local files=()
  while IFS= read -r f; do
    files+=("$f")
  done < <(ls -t "$project_dir"/*.jsonl 2>/dev/null)

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "Error: No .jsonl session files found in $project_dir" >&2
    exit 1
  fi

  echo ""
  echo "Available sessions (newest first):"
  local i=1
  for f in "${files[@]}"; do
    local fname
    fname=$(basename "$f")
    local fdate
    fdate=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$f" 2>/dev/null || date -r "$f" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "unknown")
    local fsize
    fsize=$(du -h "$f" | cut -f1 | tr -d ' ')
    local display_name="$fname"
    if [[ ${#display_name} -gt 40 ]]; then
      display_name="${display_name:0:16}...${display_name: -12}"
    fi
    printf "  %d) %s  %s  %s\n" "$i" "$fdate" "$fsize" "$display_name"
    i=$((i + 1))
  done

  local choice
  read -rp "Select session [1]: " choice
  choice="${choice:-1}"

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#files[@]} ]]; then
    echo "Error: Invalid selection" >&2
    exit 1
  fi

  SESSION_FILE="${files[$((choice - 1))]}"
}

# Argument handling
if [[ $# -eq 0 ]]; then
  resolve_session_file "$(pwd)"
elif [[ "$1" == *.jsonl ]]; then
  SESSION_FILE="$1"
elif [[ -d "$1" ]]; then
  resolve_session_file "$1"
else
  echo "Usage: $0 [--model sonnet|opus] [session.jsonl | workdir]" >&2
  exit 1
fi

# ── Validate ─────────────────────────────────────────────────────────
if [[ ! -f "$SESSION_FILE" ]]; then
  echo "Error: Session file not found: $SESSION_FILE" >&2
  exit 1
fi

if [[ ! -s "$SESSION_FILE" ]]; then
  echo "Error: Session file is empty: $SESSION_FILE" >&2
  exit 1
fi

echo ""
echo "Analyzing (LLM): $(basename "$SESSION_FILE")"
echo "Model: $MODEL"
echo ""

# ── Colors & Logging ─────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ── Stage 1: Condensation ────────────────────────────────────────────
echo -e "${BOLD}Condensing session transcript...${NC}"

CONDENSED=$(cat "$SESSION_FILE" | jq -s '
  # Helper: extract text from message content
  def extract_texts:
    if .message.content | type == "string" then [.message.content]
    elif .message.content | type == "array" then
      [.message.content[] | select(.type == "text") | .text]
    else []
    end;

  # Helper: extract tool_use blocks
  def extract_tool_uses:
    if .message.content | type == "array" then
      [.message.content[] | select(.type == "tool_use")]
    else []
    end;

  # Helper: extract tool_result blocks
  def extract_tool_results:
    if .message.content | type == "array" then
      [.message.content[] | select(.type == "tool_result")]
    else []
    end;

  # Helper: truncate string
  def trunc(n): if length > n then .[:n] + " [truncated]" else . end;

  # Helper: summarize tool detail
  def tool_detail:
    if .name == "Bash" then (.input.command // "" | trunc(200))
    elif .name == "Write" then ("file: " + (.input.file_path // "unknown") + " [" + ((.input.content // "") | length | tostring) + " chars]")
    elif .name == "Edit" then ("file: " + (.input.file_path // "unknown") + " old: " + ((.input.old_string // "") | trunc(80)) + " → new: " + ((.input.new_string // "") | trunc(80)))
    elif .name == "Read" then ("file: " + (.input.file_path // "unknown"))
    elif .name == "Grep" then ("pattern: " + (.input.pattern // "unknown"))
    elif .name == "Glob" then ("pattern: " + (.input.pattern // "unknown"))
    else (.input | tostring | trunc(150))
    end;

  # Helper: summarize tool result content
  def result_summary:
    if .content | type == "string" then .content | trunc(150)
    elif .content | type == "array" then
      [.content[] | select(.type == "text") | .text] | join(" ") | trunc(150)
    else ""
    end;

  [.[] | select(.type == "user" or .type == "assistant") | select(.isMeta != true) |
  {
    role: .type,
    ts: .timestamp,
    texts: [extract_texts[] | if .role == "user" then . else trunc(300) end],
    tools: [extract_tool_uses[] | {name: .name, detail: tool_detail}],
    results: [extract_tool_results[] | {summary: result_summary}],
    usage: .message.usage
  }
  # Drop entries with no useful content
  | select((.texts | length > 0) or (.tools | length > 0) or (.results | length > 0))
  ]
' 2>/dev/null) || {
  echo "Error: Failed to condense session file (invalid JSON?)" >&2
  exit 1
}

# Safety valve: check condensed size
CONDENSED_LEN=${#CONDENSED}
echo "Condensed to $CONDENSED_LEN chars"

if [[ "$CONDENSED_LEN" -gt 150000 ]]; then
  echo "Condensed output too large ($CONDENSED_LEN chars), applying aggressive truncation..."
  CONDENSED=$(cat "$SESSION_FILE" | jq -s '
    def extract_texts:
      if .message.content | type == "string" then [.message.content]
      elif .message.content | type == "array" then
        [.message.content[] | select(.type == "text") | .text]
      else []
      end;

    def extract_tool_uses:
      if .message.content | type == "array" then
        [.message.content[] | select(.type == "tool_use")]
      else []
      end;

    def trunc(n): if length > n then .[:n] + "..." else . end;

    [.[] | select(.type == "user" or .type == "assistant") | select(.isMeta != true) |
    {
      role: .type,
      texts: [extract_texts[] | trunc(100)],
      tools: [extract_tool_uses[] | .name]
    }
    | select((.texts | length > 0) or (.tools | length > 0))
    ]
  ' 2>/dev/null)

  CONDENSED_LEN=${#CONDENSED}
  if [[ "$CONDENSED_LEN" -gt 200000 ]]; then
    echo "Error: Session too large even after aggressive truncation ($CONDENSED_LEN chars)." >&2
    exit 1
  fi
fi

# ── Stage 2: Build prompt ────────────────────────────────────────────

PROMPT=$(cat <<'PROMPT_EOF'
You are evaluating a coding interview candidate's AI collaboration skills. The candidate was asked to build a URL shortening service using Claude Code (an AI coding assistant). Below is a condensed transcript of their Claude Code session.

Evaluate the candidate across these 5 phases using the rubric below. For each criterion, assign a score and provide a brief reason.

## Rubric

### Phase 1: Conversation Structure (25 pts)
- **Reasonable prompt count** (8 pts): 3–20 prompts suggests iterative collaboration. 1–2 = one-shot dump; >30 = excessive micro-managing.
- **Not excessively chatty** (4 pts): ≤30 prompts. More suggests inability to form coherent requests.
- **Multi-turn iteration** (8 pts): ≥3 back-and-forth turns show the candidate refined and iterated, not just fire-and-forget.
- **Session not trivially short** (5 pts): Session should span at least a few minutes, showing thoughtful engagement.

### Phase 2: Prompt Quality (20 pts)
- **Thoughtful prompts** (6 pts): Prompts should be specific, clear, and show engineering thinking — not vague ("make it work") or formulaic ("now add tests").
- **References spec/requirements** (5 pts): Candidate should reference specific requirements (URLs, ports, behaviors) from the problem statement.
- **Problem decomposition** (5 pts): Candidate breaks the problem into logical steps (setup, core logic, error handling, testing) rather than asking for everything at once.
- **Not verbatim spec paste** (4 pts): Candidate should paraphrase/decompose the spec, not just paste it wholesale.

### Phase 3: Verification & Review (25 pts)
- **Tested the service** (8 pts): Candidate ran curl commands or similar to verify the service works.
- **Multiple verification attempts** (5 pts): ≥2 distinct verification actions (different endpoints, error cases, etc.).
- **Reviewed generated code** (5 pts): Candidate read/reviewed the generated code rather than blindly accepting it.
- **Ran automated tests** (4 pts): Candidate ran test suites (go test, npm test, etc.) or asked for tests to be written and run.
- **Tested edge cases** (3 pts): Candidate tested error conditions, invalid inputs, or boundary cases.

### Phase 4: Strategic AI Usage (20 pts)
- **Tool diversity** (6 pts): Used ≥3 different tools (Bash, Read, Write, Edit, Grep, etc.) showing understanding of AI capabilities.
- **Code generation** (5 pts): AI was used to write/edit code (Write or Edit tools used).
- **Token efficiency** (5 pts): Reasonable token usage (<500k total). Excessive tokens suggest unproductive loops.
- **Iterative refinement** (4 pts): Multiple turns of refining code/approach, not just a single prompt.

### Phase 5: Engineering Depth (10 pts)
- **Security/validation awareness** (4 pts): Discussion of input validation, URL sanitization, or security concerns.
- **Error handling** (3 pts): Discussion or implementation of error handling, status codes, edge cases.
- **Beyond-spec thinking** (3 pts): Candidate considered aspects beyond the basic spec (rate limiting, caching, analytics, concurrent access, etc.).

## Session Transcript

<session>
PROMPT_EOF
)

PROMPT="${PROMPT}
${CONDENSED}
</session>

Score each criterion and provide your evaluation."

# ── Stage 3: JSON Schema ─────────────────────────────────────────────

SCHEMA=$(cat <<'SCHEMA_EOF'
{
  "type": "object",
  "required": ["phase1", "phase2", "phase3", "phase4", "phase5", "total_score", "summary", "strengths", "improvements"],
  "properties": {
    "phase1": {
      "type": "object",
      "required": ["prompt_count", "not_chatty", "multi_turn", "session_length", "subtotal"],
      "properties": {
        "prompt_count":   { "type": "object", "required": ["score", "reason"], "properties": { "score": {"type": "integer", "minimum": 0, "maximum": 8}, "reason": {"type": "string"} }, "additionalProperties": false },
        "not_chatty":     { "type": "object", "required": ["score", "reason"], "properties": { "score": {"type": "integer", "minimum": 0, "maximum": 4}, "reason": {"type": "string"} }, "additionalProperties": false },
        "multi_turn":     { "type": "object", "required": ["score", "reason"], "properties": { "score": {"type": "integer", "minimum": 0, "maximum": 8}, "reason": {"type": "string"} }, "additionalProperties": false },
        "session_length": { "type": "object", "required": ["score", "reason"], "properties": { "score": {"type": "integer", "minimum": 0, "maximum": 5}, "reason": {"type": "string"} }, "additionalProperties": false },
        "subtotal":       { "type": "integer", "minimum": 0, "maximum": 25 }
      },
      "additionalProperties": false
    },
    "phase2": {
      "type": "object",
      "required": ["thoughtful_prompts", "references_spec", "problem_decomposition", "not_spec_paste", "subtotal"],
      "properties": {
        "thoughtful_prompts":    { "type": "object", "required": ["score", "reason"], "properties": { "score": {"type": "integer", "minimum": 0, "maximum": 6}, "reason": {"type": "string"} }, "additionalProperties": false },
        "references_spec":       { "type": "object", "required": ["score", "reason"], "properties": { "score": {"type": "integer", "minimum": 0, "maximum": 5}, "reason": {"type": "string"} }, "additionalProperties": false },
        "problem_decomposition": { "type": "object", "required": ["score", "reason"], "properties": { "score": {"type": "integer", "minimum": 0, "maximum": 5}, "reason": {"type": "string"} }, "additionalProperties": false },
        "not_spec_paste":        { "type": "object", "required": ["score", "reason"], "properties": { "score": {"type": "integer", "minimum": 0, "maximum": 4}, "reason": {"type": "string"} }, "additionalProperties": false },
        "subtotal":              { "type": "integer", "minimum": 0, "maximum": 20 }
      },
      "additionalProperties": false
    },
    "phase3": {
      "type": "object",
      "required": ["tested_service", "multiple_verifications", "reviewed_code", "ran_tests", "tested_edge_cases", "subtotal"],
      "properties": {
        "tested_service":          { "type": "object", "required": ["score", "reason"], "properties": { "score": {"type": "integer", "minimum": 0, "maximum": 8}, "reason": {"type": "string"} }, "additionalProperties": false },
        "multiple_verifications":  { "type": "object", "required": ["score", "reason"], "properties": { "score": {"type": "integer", "minimum": 0, "maximum": 5}, "reason": {"type": "string"} }, "additionalProperties": false },
        "reviewed_code":           { "type": "object", "required": ["score", "reason"], "properties": { "score": {"type": "integer", "minimum": 0, "maximum": 5}, "reason": {"type": "string"} }, "additionalProperties": false },
        "ran_tests":               { "type": "object", "required": ["score", "reason"], "properties": { "score": {"type": "integer", "minimum": 0, "maximum": 4}, "reason": {"type": "string"} }, "additionalProperties": false },
        "tested_edge_cases":       { "type": "object", "required": ["score", "reason"], "properties": { "score": {"type": "integer", "minimum": 0, "maximum": 3}, "reason": {"type": "string"} }, "additionalProperties": false },
        "subtotal":                { "type": "integer", "minimum": 0, "maximum": 25 }
      },
      "additionalProperties": false
    },
    "phase4": {
      "type": "object",
      "required": ["tool_diversity", "code_generation", "token_efficiency", "iterative_refinement", "subtotal"],
      "properties": {
        "tool_diversity":        { "type": "object", "required": ["score", "reason"], "properties": { "score": {"type": "integer", "minimum": 0, "maximum": 6}, "reason": {"type": "string"} }, "additionalProperties": false },
        "code_generation":       { "type": "object", "required": ["score", "reason"], "properties": { "score": {"type": "integer", "minimum": 0, "maximum": 5}, "reason": {"type": "string"} }, "additionalProperties": false },
        "token_efficiency":      { "type": "object", "required": ["score", "reason"], "properties": { "score": {"type": "integer", "minimum": 0, "maximum": 5}, "reason": {"type": "string"} }, "additionalProperties": false },
        "iterative_refinement":  { "type": "object", "required": ["score", "reason"], "properties": { "score": {"type": "integer", "minimum": 0, "maximum": 4}, "reason": {"type": "string"} }, "additionalProperties": false },
        "subtotal":              { "type": "integer", "minimum": 0, "maximum": 20 }
      },
      "additionalProperties": false
    },
    "phase5": {
      "type": "object",
      "required": ["security_awareness", "error_handling", "beyond_spec", "subtotal"],
      "properties": {
        "security_awareness": { "type": "object", "required": ["score", "reason"], "properties": { "score": {"type": "integer", "minimum": 0, "maximum": 4}, "reason": {"type": "string"} }, "additionalProperties": false },
        "error_handling":     { "type": "object", "required": ["score", "reason"], "properties": { "score": {"type": "integer", "minimum": 0, "maximum": 3}, "reason": {"type": "string"} }, "additionalProperties": false },
        "beyond_spec":        { "type": "object", "required": ["score", "reason"], "properties": { "score": {"type": "integer", "minimum": 0, "maximum": 3}, "reason": {"type": "string"} }, "additionalProperties": false },
        "subtotal":           { "type": "integer", "minimum": 0, "maximum": 10 }
      },
      "additionalProperties": false
    },
    "total_score": { "type": "integer", "minimum": 0, "maximum": 100 },
    "summary":     { "type": "string" },
    "strengths":   { "type": "array", "items": { "type": "string" } },
    "improvements": { "type": "array", "items": { "type": "string" } }
  },
  "additionalProperties": false
}
SCHEMA_EOF
)

# ── Stage 4: LLM Call ────────────────────────────────────────────────
echo -e "${BOLD}Calling Claude ($MODEL) for evaluation...${NC}"
echo ""

LLM_OUTPUT=""
ATTEMPT=0
MAX_ATTEMPTS=2

while [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; do
  ATTEMPT=$((ATTEMPT + 1))

  LLM_OUTPUT=$(echo "$PROMPT" | claude --print --output-format json --json-schema "$SCHEMA" --model "$MODEL" 2>/dev/null) && break

  if [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; then
    echo "LLM call failed (attempt $ATTEMPT/$MAX_ATTEMPTS), retrying..." >&2
  fi
done

if [[ -z "$LLM_OUTPUT" ]]; then
  echo "Error: LLM evaluation failed after $MAX_ATTEMPTS attempts." >&2
  exit 1
fi

# Validate JSON
if ! echo "$LLM_OUTPUT" | jq '.' &>/dev/null; then
  echo "Error: LLM returned invalid JSON." >&2
  echo "Raw output:" >&2
  echo "$LLM_OUTPUT" | head -20 >&2
  exit 1
fi

# ── Stage 5: Render Results ──────────────────────────────────────────

# Helper: print a criterion result
print_criterion() {
  local phase="$1" key="$2" max_pts="$3" desc="$4"
  local score reason
  score=$(echo "$LLM_OUTPUT" | jq -r ".${phase}.${key}.score")
  reason=$(echo "$LLM_OUTPUT" | jq -r ".${phase}.${key}.reason")

  if [[ "$score" -eq "$max_pts" ]]; then
    echo -e "  ${GREEN}✓${NC} [+${score}] ${desc} — ${reason}"
  elif [[ "$score" -gt 0 ]]; then
    echo -e "  ${YELLOW}◐${NC} [+${score}/${max_pts}] ${desc} — ${reason}"
  else
    echo -e "  ${RED}✗${NC} [+0/${max_pts}] ${desc} — ${reason}"
  fi
}

# Phase 1
echo -e "${BOLD}${BLUE}Phase 1: Conversation Structure (25 pts)${NC}"
print_criterion "phase1" "prompt_count"   8 "Reasonable prompt count"
print_criterion "phase1" "not_chatty"     4 "Not excessively chatty"
print_criterion "phase1" "multi_turn"     8 "Multi-turn iteration"
print_criterion "phase1" "session_length" 5 "Session not trivially short"

# Phase 2
echo -e "\n${BOLD}${BLUE}Phase 2: Prompt Quality (20 pts)${NC}"
print_criterion "phase2" "thoughtful_prompts"    6 "Thoughtful prompts"
print_criterion "phase2" "references_spec"       5 "References spec/requirements"
print_criterion "phase2" "problem_decomposition" 5 "Problem decomposition"
print_criterion "phase2" "not_spec_paste"        4 "Not verbatim spec paste"

# Phase 3
echo -e "\n${BOLD}${BLUE}Phase 3: Verification & Review (25 pts)${NC}"
print_criterion "phase3" "tested_service"         8 "Tested the service"
print_criterion "phase3" "multiple_verifications" 5 "Multiple verification attempts"
print_criterion "phase3" "reviewed_code"          5 "Reviewed generated code"
print_criterion "phase3" "ran_tests"              4 "Ran automated tests"
print_criterion "phase3" "tested_edge_cases"      3 "Tested edge cases"

# Phase 4
echo -e "\n${BOLD}${BLUE}Phase 4: Strategic AI Usage (20 pts)${NC}"
print_criterion "phase4" "tool_diversity"       6 "Tool diversity"
print_criterion "phase4" "code_generation"      5 "Code generation"
print_criterion "phase4" "token_efficiency"     5 "Token efficiency"
print_criterion "phase4" "iterative_refinement" 4 "Iterative refinement"

# Phase 5
echo -e "\n${BOLD}${BLUE}Phase 5: Engineering Depth (10 pts)${NC}"
print_criterion "phase5" "security_awareness" 4 "Security/validation awareness"
print_criterion "phase5" "error_handling"     3 "Error handling"
print_criterion "phase5" "beyond_spec"        3 "Beyond-spec thinking"

# ── Recompute total from individual scores (don't trust LLM arithmetic) ──
SCORE=$(echo "$LLM_OUTPUT" | jq '
  [
    .phase1.prompt_count.score, .phase1.not_chatty.score, .phase1.multi_turn.score, .phase1.session_length.score,
    .phase2.thoughtful_prompts.score, .phase2.references_spec.score, .phase2.problem_decomposition.score, .phase2.not_spec_paste.score,
    .phase3.tested_service.score, .phase3.multiple_verifications.score, .phase3.reviewed_code.score, .phase3.ran_tests.score, .phase3.tested_edge_cases.score,
    .phase4.tool_diversity.score, .phase4.code_generation.score, .phase4.token_efficiency.score, .phase4.iterative_refinement.score,
    .phase5.security_awareness.score, .phase5.error_handling.score, .phase5.beyond_spec.score
  ] | add
')

# Recompute subtotals
P1=$(echo "$LLM_OUTPUT" | jq '[.phase1.prompt_count.score, .phase1.not_chatty.score, .phase1.multi_turn.score, .phase1.session_length.score] | add')
P2=$(echo "$LLM_OUTPUT" | jq '[.phase2.thoughtful_prompts.score, .phase2.references_spec.score, .phase2.problem_decomposition.score, .phase2.not_spec_paste.score] | add')
P3=$(echo "$LLM_OUTPUT" | jq '[.phase3.tested_service.score, .phase3.multiple_verifications.score, .phase3.reviewed_code.score, .phase3.ran_tests.score, .phase3.tested_edge_cases.score] | add')
P4=$(echo "$LLM_OUTPUT" | jq '[.phase4.tool_diversity.score, .phase4.code_generation.score, .phase4.token_efficiency.score, .phase4.iterative_refinement.score] | add')
P5=$(echo "$LLM_OUTPUT" | jq '[.phase5.security_awareness.score, .phase5.error_handling.score, .phase5.beyond_spec.score] | add')

PASS=$(echo "$LLM_OUTPUT" | jq '[
  .phase1.prompt_count.score, .phase1.not_chatty.score, .phase1.multi_turn.score, .phase1.session_length.score,
  .phase2.thoughtful_prompts.score, .phase2.references_spec.score, .phase2.problem_decomposition.score, .phase2.not_spec_paste.score,
  .phase3.tested_service.score, .phase3.multiple_verifications.score, .phase3.reviewed_code.score, .phase3.ran_tests.score, .phase3.tested_edge_cases.score,
  .phase4.tool_diversity.score, .phase4.code_generation.score, .phase4.token_efficiency.score, .phase4.iterative_refinement.score,
  .phase5.security_awareness.score, .phase5.error_handling.score, .phase5.beyond_spec.score
] | map(select(. > 0)) | length')

FAIL=$(echo "$LLM_OUTPUT" | jq '[
  .phase1.prompt_count.score, .phase1.not_chatty.score, .phase1.multi_turn.score, .phase1.session_length.score,
  .phase2.thoughtful_prompts.score, .phase2.references_spec.score, .phase2.problem_decomposition.score, .phase2.not_spec_paste.score,
  .phase3.tested_service.score, .phase3.multiple_verifications.score, .phase3.reviewed_code.score, .phase3.ran_tests.score, .phase3.tested_edge_cases.score,
  .phase4.tool_diversity.score, .phase4.code_generation.score, .phase4.token_efficiency.score, .phase4.iterative_refinement.score,
  .phase5.security_awareness.score, .phase5.error_handling.score, .phase5.beyond_spec.score
] | map(select(. == 0)) | length')

TOTAL=$((PASS + FAIL))

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo -e "  Phase subtotals: ${P1}/25  ${P2}/20  ${P3}/25  ${P4}/20  ${P5}/10"

echo -e "\n${BOLD}════════════════════════════════════════${NC}"
echo -e "${BOLD}  Results: ${GREEN}${PASS} passed${NC} / ${RED}${FAIL} failed${NC} (${TOTAL} criteria)"
echo -e "${BOLD}  Score:   ${SCORE} / 100${NC}"

if [[ $SCORE -ge 90 ]]; then
  GRADE="A"; COLOR="$GREEN"; INTERP="Exceptional AI collaboration"
elif [[ $SCORE -ge 75 ]]; then
  GRADE="B"; COLOR="$GREEN"; INTERP="Good — iterative and thoughtful"
elif [[ $SCORE -ge 60 ]]; then
  GRADE="C"; COLOR="$YELLOW"; INTERP="Acceptable — some verification gaps"
elif [[ $SCORE -ge 40 ]]; then
  GRADE="D"; COLOR="$RED"; INTERP="Weak — mostly one-shot"
else
  GRADE="F"; COLOR="$RED"; INTERP="No meaningful AI collaboration"
fi

echo -e "${BOLD}  Grade:   ${COLOR}${GRADE}${NC} — ${INTERP}"
echo -e "${BOLD}════════════════════════════════════════${NC}"

# ── Qualitative feedback ─────────────────────────────────────────────
SUMMARY=$(echo "$LLM_OUTPUT" | jq -r '.summary')
echo ""
echo -e "${BOLD}Summary:${NC} $SUMMARY"

echo ""
echo -e "${BOLD}${GREEN}Strengths:${NC}"
echo "$LLM_OUTPUT" | jq -r '.strengths[]' | while read -r s; do
  echo -e "  ${GREEN}•${NC} $s"
done

echo ""
echo -e "${BOLD}${YELLOW}Areas for improvement:${NC}"
echo "$LLM_OUTPUT" | jq -r '.improvements[]' | while read -r s; do
  echo -e "  ${YELLOW}•${NC} $s"
done

echo ""
exit 0
EVALUATE_AI_LLM_HEREDOC_EOF

cat > "$INSTALL_DIR/eval.sh" << 'EVAL_HEREDOC_EOF'
#!/usr/bin/env bash
set -euo pipefail

# Resolve symlinks so we find sibling scripts even when invoked via a symlink
SOURCE="$0"
while [[ -L "$SOURCE" ]]; do
  SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$SCRIPT_DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"

VERSION="0.6.1"

# ── Usage ────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 <command> [options]

Commands:
  setup                Copy problem.md into the current directory to start an interview
  cleanup              Remove all files in the current directory except problem.md
  update               Re-run the installer to update all toolkit files
  update --force       Force re-download even if already on latest version
  (default)            Run evaluations (functional and/or AI collaboration)

Options (for evaluation):
  -u, --url URL        Base URL for functional tests (default: http://localhost:8787)
  -s, --session FILE   Session JSONL file for AI evaluation
  -w, --workdir DIR    Working directory for session discovery (default: CWD)
  -f, --functional     Run only functional evaluation
  -a, --ai-only        Run only AI collaboration evaluation
  --model MODEL        LLM model for AI evaluation (default: sonnet)
  -v, --version        Show version
  -h, --help           Show this help

Examples:
  $0 setup                                   # copy problem.md to CWD
  $0 cleanup                                 # clean CWD, keep problem.md
  $0 update                                  # update toolkit to latest version
  $0 update --force                          # force re-download all files
  $0                                         # both evals, defaults
  $0 -u http://localhost:3000                # custom URL, both evals
  $0 -s /path/to/session.jsonl              # both evals, explicit session
  $0 -f                                      # functional only
  $0 -a -s /path/to/session.jsonl           # AI only
  $0 --model opus -a -s file.jsonl         # AI eval with Opus model
EOF
  exit 0
}

# ── Subcommands ──────────────────────────────────────────────────────
case "${1:-}" in
  setup)
    if [[ ! -f "$SCRIPT_DIR/problem.md" ]]; then
      echo "Error: problem.md not found in $SCRIPT_DIR" >&2
      exit 1
    fi
    cp "$SCRIPT_DIR/problem.md" ./problem.md
    echo "Copied problem.md to $(pwd)/problem.md"
    exit 0
    ;;
  update)
    FORCE_UPDATE=false
    [[ "${2:-}" == "--force" ]] && FORCE_UPDATE=true
    OLD_VERSION="$VERSION"
    echo "Checking for updates (current: v${OLD_VERSION})..."
    # Run installer, capture output but suppress it
    INSTALL_OUTPUT=$(curl -fsSL https://raw.githubusercontent.com/wayou/onsite-interview/master/install.sh | bash 2>&1)
    # Re-read the new version from the freshly downloaded eval.sh
    NEW_VERSION=$(grep -m1 '^VERSION=' "$SCRIPT_DIR/eval.sh" | cut -d'"' -f2)
    if [[ "$OLD_VERSION" == "$NEW_VERSION" ]] && [[ "$FORCE_UPDATE" == "false" ]]; then
      echo "Already up to date (v${OLD_VERSION})."
    elif [[ "$OLD_VERSION" == "$NEW_VERSION" ]]; then
      echo "Force re-downloaded all files (v${OLD_VERSION})."
    else
      echo "Updated from v${OLD_VERSION} to v${NEW_VERSION}."
    fi
    exit 0
    ;;
  cleanup)
    # Remove everything in CWD except problem.md
    shopt -s dotglob
    for item in *; do
      [[ "$item" == "problem.md" ]] && continue
      rm -rf "$item"
    done
    shopt -u dotglob
    echo "Cleaned up $(pwd) (kept problem.md)"
    exit 0
    ;;
esac

# ── Defaults ─────────────────────────────────────────────────────────
BASE_URL="http://localhost:8787"
SESSION_ARG=""
RUN_FUNCTIONAL=true
RUN_AI=true
LLM_MODEL=""

# ── Parse args ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--url)       BASE_URL="$2"; shift 2 ;;
    -s|--session)   SESSION_ARG="$2"; shift 2 ;;
    -w|--workdir)   SESSION_ARG="$2"; shift 2 ;;
    -f|--functional) RUN_FUNCTIONAL=true; RUN_AI=false; shift ;;
    -a|--ai-only)   RUN_AI=true; RUN_FUNCTIONAL=false; shift ;;
    --model)        LLM_MODEL="$2"; shift 2 ;;
    -v|--version)   echo "assess $VERSION"; exit 0 ;;
    -h|--help)      usage ;;
    *)              echo "Unknown option: $1" >&2; usage ;;
  esac
done

# ── Colors ───────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

FUNC_SCORE=""
AI_SCORE=""

# ── Run functional evaluation ────────────────────────────────────────
if [[ "$RUN_FUNCTIONAL" == "true" ]]; then
  echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${BLUE}║   FUNCTIONAL EVALUATION (evaluate.sh)    ║${NC}"
  echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════╝${NC}"
  echo ""

  # Capture output and extract score
  FUNC_OUTPUT=$("$SCRIPT_DIR/evaluate.sh" "$BASE_URL" 2>&1) || true
  echo "$FUNC_OUTPUT"

  # Extract score from output (matches "Score:   XX / 100")
  FUNC_SCORE=$(echo "$FUNC_OUTPUT" | sed -n 's/.*Score:[[:space:]]*\([0-9]*\)[[:space:]]*\/.*/\1/p' | tail -1)
fi

# ── Run AI collaboration evaluation ─────────────────────────────────
if [[ "$RUN_AI" == "true" ]]; then
  AI_EVAL_SCRIPT="evaluate-ai-llm.sh"
  AI_EVAL_LABEL="AI COLLABORATION (LLM)"

  echo ""
  echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════╗${NC}"
  printf "${BOLD}${BLUE}║   %-39s║${NC}\n" "$AI_EVAL_LABEL"
  echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════╝${NC}"
  echo ""

  # Build evaluator args
  AI_EVAL_ARGS=()
  if [[ -n "$LLM_MODEL" ]]; then
    AI_EVAL_ARGS+=(--model "$LLM_MODEL")
  fi

  if [[ -n "$SESSION_ARG" ]]; then
    AI_OUTPUT=$("$SCRIPT_DIR/$AI_EVAL_SCRIPT" ${AI_EVAL_ARGS[@]+"${AI_EVAL_ARGS[@]}"} "$SESSION_ARG" 2>&1) || true
  else
    # Interactive mode — pass through stdin
    "$SCRIPT_DIR/$AI_EVAL_SCRIPT" ${AI_EVAL_ARGS[@]+"${AI_EVAL_ARGS[@]}"}
    # Can't capture score in interactive mode, skip combined summary
    AI_SCORE=""
    RUN_AI="interactive"
  fi

  if [[ "$RUN_AI" != "interactive" ]]; then
    echo "$AI_OUTPUT"
    AI_SCORE=$(echo "$AI_OUTPUT" | sed -n 's/.*Score:[[:space:]]*\([0-9]*\)[[:space:]]*\/.*/\1/p' | tail -1)
  fi
fi

# ── Combined Summary ─────────────────────────────────────────────────
if [[ "$RUN_FUNCTIONAL" == "true" ]] && [[ -n "$AI_SCORE" ]]; then
  COMBINED=$(( (${FUNC_SCORE:-0} + ${AI_SCORE:-0}) / 2 ))

  if [[ $COMBINED -ge 90 ]]; then
    GRADE="A"; COLOR="$GREEN"; INTERP="Exceptional candidate"
  elif [[ $COMBINED -ge 75 ]]; then
    GRADE="B"; COLOR="$GREEN"; INTERP="Strong candidate"
  elif [[ $COMBINED -ge 60 ]]; then
    GRADE="C"; COLOR="$YELLOW"; INTERP="Acceptable — has gaps"
  elif [[ $COMBINED -ge 40 ]]; then
    GRADE="D"; COLOR="$RED"; INTERP="Below bar"
  else
    GRADE="F"; COLOR="$RED"; INTERP="Not recommended"
  fi

  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║          COMBINED RESULTS                ║${NC}"
  echo -e "${BOLD}╠══════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}║  Functional:      ${FUNC_SCORE:-?} / 100               ║${NC}"
  echo -e "${BOLD}║  AI Collaboration: ${AI_SCORE:-?} / 100               ║${NC}"
  echo -e "${BOLD}║  ────────────────────────────────        ║${NC}"
  echo -e "${BOLD}║  Overall:         ${COMBINED} / 100               ║${NC}"
  echo -e "${BOLD}║  Grade:           ${COLOR}${GRADE}${NC}${BOLD} — ${INTERP}$(printf '%*s' $((17 - ${#INTERP})) '')║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
  echo ""
fi

exit 0
EVAL_HEREDOC_EOF

chmod +x "$INSTALL_DIR/evaluate.sh" "$INSTALL_DIR/evaluate-ai-llm.sh" "$INSTALL_DIR/eval.sh"

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
