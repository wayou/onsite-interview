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
