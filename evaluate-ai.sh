#!/usr/bin/env bash
set -euo pipefail

# ── Session Discovery ─────────────────────────────────────────────────
SESSION_FILE=""

resolve_session_file() {
  local workdir="${1:-$(pwd)}"
  workdir="$(cd "$workdir" && pwd)"  # resolve to absolute path

  # Derive Claude Code project path: /Users/foo/bar → ~/.claude/projects/-Users-foo-bar/
  local project_dir="$HOME/.claude/projects/-${workdir#/}"
  project_dir="${project_dir//\//-}"
  # Fix: the first segment after projects/ should start with -, rest use - for /
  project_dir="$HOME/.claude/projects/$(echo "${workdir}" | sed 's|/|-|g')"

  if [[ ! -d "$project_dir" ]]; then
    echo "Error: No Claude Code project found at $project_dir" >&2
    exit 1
  fi

  # List .jsonl files sorted newest-first
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
    # Truncate long filenames for display
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
  echo "Usage: $0 [session.jsonl | workdir]" >&2
  exit 1
fi

# ── Validate ──────────────────────────────────────────────────────────
if [[ ! -f "$SESSION_FILE" ]]; then
  echo "Error: Session file not found: $SESSION_FILE" >&2
  exit 1
fi

if [[ ! -s "$SESSION_FILE" ]]; then
  echo "Error: Session file is empty: $SESSION_FILE" >&2
  exit 1
fi

echo ""
echo "Analyzing: $(basename "$SESSION_FILE")"
echo ""

# ── Colors & Logging (same as evaluate.sh) ────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

TOTAL=0
PASS=0
FAIL=0
SCORE=0

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

# ── Single-pass jq extraction ─────────────────────────────────────────
METRICS=$(cat "$SESSION_FILE" | jq -s '
  # Helper: extract text from message content (handles both string and array formats)
  def extract_texts:
    if .message.content | type == "string" then [.message.content]
    elif .message.content | type == "array" then
      [.message.content[] | select(.type == "text") | .text]
    else []
    end;

  # Helper: extract tool_use blocks from message content array
  def extract_tool_uses:
    if .message.content | type == "array" then
      [.message.content[] | select(.type == "tool_use")]
    else []
    end;

  # User text prompts (non-meta, excluding tool_result messages)
  [.[] | select(.type == "user" and (.isMeta != true))
    | extract_texts[]] as $user_texts |

  # All assistant tool_use blocks
  [.[] | select(.type == "assistant" and (.isMeta != true))
    | extract_tool_uses[]] as $tool_uses |

  # Bash commands from tool_use
  [$tool_uses[] | select(.name == "Bash") | .input.command // empty] as $bash_cmds |

  # All text content (user + assistant) for keyword searching
  [.[] | select(.type == "user" or .type == "assistant") | select(.isMeta != true)
    | extract_texts[]] as $all_texts |

  # Timestamps
  [.[] | .timestamp // empty | select(. != null and . != "")] as $timestamps |

  # Token usage from assistant messages
  [.[] | select(.type == "assistant") | .message.usage // empty | select(. != null)] as $usages |

  # Assistant response count
  [.[] | select(.type == "assistant" and (.isMeta != true))] | length as $assistant_count |

  # Unique tool names
  [$tool_uses[] | .name] | unique as $tool_names |

  # Read tool count
  [$tool_uses[] | select(.name == "Read")] | length as $read_count |

  # Write/Edit tool usage
  ([$tool_uses[] | select(.name == "Write" or .name == "Edit")] | length > 0) as $has_write_edit |

  # Compute user prompt lengths
  [$user_texts[] | length] as $prompt_lengths |

  # Total tokens
  ([$usages[] | (.input_tokens // 0) + (.output_tokens // 0)] | add // 0) as $total_tokens |

  # Joined text for keyword searching
  ($all_texts | join(" ") | ascii_downcase) as $all_text_lower |
  ($user_texts | join(" ") | ascii_downcase) as $user_text_lower |
  ($bash_cmds | join(" ") | ascii_downcase) as $bash_text_lower |

  # Longest user prompt
  ([$user_texts[] | length] | max // 0) as $longest_prompt |

  # Count spec keywords across different user prompts
  ([$user_texts[] | ascii_downcase |
    select(test("url|shorten|redirect|8787|localhost"))]
    | length) as $spec_keyword_prompts |

  # Count distinct topic keywords across different user prompts
  [
    ([$user_texts[] | ascii_downcase | select(test("test"))] | length > 0),
    ([$user_texts[] | ascii_downcase | select(test("error"))] | length > 0),
    ([$user_texts[] | ascii_downcase | select(test("valid"))] | length > 0),
    ([$user_texts[] | ascii_downcase | select(test("secur"))] | length > 0),
    ([$user_texts[] | ascii_downcase | select(test("status"))] | length > 0)
  ] | map(select(. == true)) | length as $topic_count |

  # Curl commands hitting localhost
  [$bash_cmds[] | select(test("curl.*localhost"; "i"))] as $curl_cmds |

  # Test commands
  [$bash_cmds[] | select(test("go test|npm test|pytest|cargo test|jest|mocha|make test"; "i"))] as $test_cmds |

  # Error/edge-case curl commands
  [$bash_cmds[] | select(test("curl"; "i"))
    | select(test("invalid|not-a|error|nonexist|empty|bad|404|400|javascript:|data:|DROP"; "i"))] as $edge_curl_cmds |

  # Problem.md signature detection (common phrases from spec)
  ($user_text_lower | test("build a url shortening service.*that listens on port")) as $has_spec_paste |

  {
    user_prompt_count: ($user_texts | length),
    assistant_count: $assistant_count,
    prompt_lengths: $prompt_lengths,
    avg_prompt_length: (if ($prompt_lengths | length) > 0 then ($prompt_lengths | add / length | floor) else 0 end),
    longest_prompt: $longest_prompt,
    first_timestamp: ($timestamps | first // null),
    last_timestamp: ($timestamps | last // null),
    total_tokens: $total_tokens,
    tool_names: $tool_names,
    tool_count: ($tool_names | length),
    read_count: $read_count,
    has_write_edit: $has_write_edit,
    curl_localhost_count: ($curl_cmds | length),
    test_cmd_count: ($test_cmds | length),
    edge_curl_count: ($edge_curl_cmds | length),
    spec_keyword_prompts: $spec_keyword_prompts,
    topic_count: $topic_count,
    has_spec_paste: $has_spec_paste,
    has_security_keywords: ($all_text_lower | test("valid|invalid|secur|inject|xss|sanitiz")),
    has_error_keywords: ($all_text_lower | test("error|404|400|not found")),
    has_beyond_spec: ($all_text_lower | test("rate.?limit|analytics|cache|concurrent|duplicate|idempoten"))
  }
')

# ── Helper to extract metric values ──────────────────────────────────
m() {
  echo "$METRICS" | jq -r "$1"
}

# ── Phase 1: Conversation Structure (25 pts) ─────────────────────────

echo -e "${BOLD}${BLUE}Phase 1: Conversation Structure (25 pts)${NC}"

PROMPT_COUNT=$(m '.user_prompt_count')
ASSISTANT_COUNT=$(m '.assistant_count')

# Test: Reasonable prompt count (3–20)
if [[ "$PROMPT_COUNT" -ge 3 ]] && [[ "$PROMPT_COUNT" -le 20 ]]; then
  log_pass 8 "Reasonable prompt count ($PROMPT_COUNT prompts, range 3–20)"
elif [[ "$PROMPT_COUNT" -eq 0 ]]; then
  log_fail 8 "Reasonable prompt count" "no user prompts found"
elif [[ "$PROMPT_COUNT" -lt 3 ]]; then
  log_fail 8 "Reasonable prompt count" "only $PROMPT_COUNT prompts (one-shot dump?)"
else
  log_fail 8 "Reasonable prompt count" "$PROMPT_COUNT prompts (outside 3–20 range)"
fi

# Test: Not excessively chatty
if [[ "$PROMPT_COUNT" -le 30 ]]; then
  log_pass 4 "Not excessively chatty ($PROMPT_COUNT ≤ 30)"
else
  log_fail 4 "Not excessively chatty" "$PROMPT_COUNT prompts (>30)"
fi

# Test: Multi-turn iteration
if [[ "$ASSISTANT_COUNT" -ge 3 ]]; then
  log_pass 8 "Multi-turn iteration ($ASSISTANT_COUNT assistant responses)"
else
  log_fail 8 "Multi-turn iteration" "only $ASSISTANT_COUNT assistant responses (<3)"
fi

# Test: Session not trivially short
FIRST_TS=$(m '.first_timestamp')
LAST_TS=$(m '.last_timestamp')
if [[ "$FIRST_TS" != "null" ]] && [[ "$LAST_TS" != "null" ]]; then
  # Parse ISO 8601 timestamps to epoch seconds
  FIRST_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${FIRST_TS%%.*}" "+%s" 2>/dev/null || date -d "${FIRST_TS}" "+%s" 2>/dev/null || echo "0")
  LAST_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${LAST_TS%%.*}" "+%s" 2>/dev/null || date -d "${LAST_TS}" "+%s" 2>/dev/null || echo "0")
  DURATION_SECS=$(( LAST_EPOCH - FIRST_EPOCH ))
  DURATION_MINS=$(( DURATION_SECS / 60 ))
  if [[ "$DURATION_SECS" -ge 120 ]]; then
    log_pass 5 "Session not trivially short (${DURATION_MINS} min)"
  else
    log_fail 5 "Session not trivially short" "only ${DURATION_SECS}s (<2 min)"
  fi
else
  log_fail 5 "Session not trivially short" "could not determine timestamps"
fi

# ── Phase 2: Prompt Quality (20 pts) ─────────────────────────────────

echo -e "\n${BOLD}${BLUE}Phase 2: Prompt Quality (20 pts)${NC}"

AVG_PROMPT_LEN=$(m '.avg_prompt_length')
LONGEST_PROMPT=$(m '.longest_prompt')
SPEC_KEYWORD_PROMPTS=$(m '.spec_keyword_prompts')
TOPIC_COUNT=$(m '.topic_count')
HAS_SPEC_PASTE=$(m '.has_spec_paste')

# Test: Average prompt length reasonable (20–500 chars)
if [[ "$AVG_PROMPT_LEN" -ge 20 ]] && [[ "$AVG_PROMPT_LEN" -le 500 ]]; then
  log_pass 6 "Average prompt length reasonable (${AVG_PROMPT_LEN} chars, range 20–500)"
elif [[ "$AVG_PROMPT_LEN" -lt 20 ]]; then
  log_fail 6 "Average prompt length reasonable" "avg ${AVG_PROMPT_LEN} chars (too short)"
else
  log_fail 6 "Average prompt length reasonable" "avg ${AVG_PROMPT_LEN} chars (too long)"
fi

# Test: References spec/requirements
if [[ "$SPEC_KEYWORD_PROMPTS" -ge 1 ]]; then
  log_pass 5 "References spec/requirements ($SPEC_KEYWORD_PROMPTS prompts with spec keywords)"
else
  log_fail 5 "References spec/requirements" "no prompts mention url/shorten/redirect/8787/localhost"
fi

# Test: Problem decomposition
if [[ "$TOPIC_COUNT" -ge 2 ]]; then
  log_pass 5 "Problem decomposition ($TOPIC_COUNT distinct topics across prompts)"
else
  log_fail 5 "Problem decomposition" "only $TOPIC_COUNT topic(s) — prompts lack variety"
fi

# Test: Not verbatim spec paste
if [[ "$LONGEST_PROMPT" -lt 2000 ]] || [[ "$HAS_SPEC_PASTE" == "false" ]]; then
  log_pass 4 "Not verbatim spec paste (longest prompt: ${LONGEST_PROMPT} chars)"
else
  log_fail 4 "Not verbatim spec paste" "detected large copy-paste (${LONGEST_PROMPT} chars with spec signatures)"
fi

# ── Phase 3: Verification & Review (25 pts) ──────────────────────────

echo -e "\n${BOLD}${BLUE}Phase 3: Verification & Review (25 pts)${NC}"

CURL_COUNT=$(m '.curl_localhost_count')
READ_COUNT=$(m '.read_count')
TEST_CMD_COUNT=$(m '.test_cmd_count')
EDGE_CURL_COUNT=$(m '.edge_curl_count')

# Test: Ran curl against service
if [[ "$CURL_COUNT" -ge 1 ]]; then
  log_pass 8 "Ran curl against service ($CURL_COUNT curl commands)"
else
  log_fail 8 "Ran curl against service" "no curl.*localhost commands found"
fi

# Test: Multiple verification attempts
if [[ "$CURL_COUNT" -ge 2 ]]; then
  log_pass 5 "Multiple verification attempts ($CURL_COUNT curl/test commands)"
else
  log_fail 5 "Multiple verification attempts" "only $CURL_COUNT curl commands (need ≥2)"
fi

# Test: Reviewed generated code (Read tool)
if [[ "$READ_COUNT" -ge 1 ]]; then
  log_pass 5 "Reviewed generated code ($READ_COUNT Read tool uses)"
else
  log_fail 5 "Reviewed generated code" "Read tool never used"
fi

# Test: Ran tests or test commands
if [[ "$TEST_CMD_COUNT" -ge 1 ]]; then
  log_pass 4 "Ran tests or test commands ($TEST_CMD_COUNT test commands)"
else
  log_fail 4 "Ran tests or test commands" "no test commands found"
fi

# Test: Tested error/edge cases
if [[ "$EDGE_CURL_COUNT" -ge 1 ]]; then
  log_pass 3 "Tested error/edge cases ($EDGE_CURL_COUNT edge-case requests)"
else
  log_fail 3 "Tested error/edge cases" "only happy-path testing detected"
fi

# ── Phase 4: Strategic AI Usage (20 pts) ─────────────────────────────

echo -e "\n${BOLD}${BLUE}Phase 4: Strategic AI Usage (20 pts)${NC}"

TOOL_COUNT=$(m '.tool_count')
TOOL_NAMES=$(m '.tool_names | join(", ")')
HAS_WRITE_EDIT=$(m '.has_write_edit')
TOTAL_TOKENS=$(m '.total_tokens')

# Test: Tool diversity (≥3 distinct tools)
if [[ "$TOOL_COUNT" -ge 3 ]]; then
  log_pass 6 "Tool diversity ($TOOL_COUNT tools: $TOOL_NAMES)"
else
  log_pass 0 "" >/dev/null 2>&1 || true  # no-op
  log_fail 6 "Tool diversity" "only $TOOL_COUNT tool(s): $TOOL_NAMES"
fi

# Test: Code generation (Write/Edit used)
if [[ "$HAS_WRITE_EDIT" == "true" ]]; then
  log_pass 5 "Code generation (Write/Edit used)"
else
  log_fail 5 "Code generation" "neither Write nor Edit tool used"
fi

# Test: Token efficiency (<500k total)
if [[ "$TOTAL_TOKENS" -lt 500000 ]]; then
  TOKENS_K=$((TOTAL_TOKENS / 1000))
  log_pass 5 "Token efficiency (${TOKENS_K}k tokens, <500k)"
else
  TOKENS_K=$((TOTAL_TOKENS / 1000))
  log_fail 5 "Token efficiency" "${TOKENS_K}k tokens (≥500k)"
fi

# Test: Iterative (>1 conversation turn)
if [[ "$PROMPT_COUNT" -gt 1 ]]; then
  log_pass 4 "Iterative conversation ($PROMPT_COUNT user turns)"
else
  log_fail 4 "Iterative conversation" "only $PROMPT_COUNT user turn"
fi

# ── Phase 5: Engineering Depth (10 pts) ──────────────────────────────

echo -e "\n${BOLD}${BLUE}Phase 5: Engineering Depth (10 pts)${NC}"

HAS_SECURITY=$(m '.has_security_keywords')
HAS_ERROR=$(m '.has_error_keywords')
HAS_BEYOND=$(m '.has_beyond_spec')

# Test: Security/validation discussed
if [[ "$HAS_SECURITY" == "true" ]]; then
  log_pass 4 "Security/validation discussed"
else
  log_fail 4 "Security/validation discussed" "no security-related keywords found"
fi

# Test: Error handling discussed
if [[ "$HAS_ERROR" == "true" ]]; then
  log_pass 3 "Error handling discussed"
else
  log_fail 3 "Error handling discussed" "no error-handling keywords found"
fi

# Test: Beyond-spec features discussed
if [[ "$HAS_BEYOND" == "true" ]]; then
  log_pass 3 "Beyond-spec features discussed"
else
  log_fail 3 "Beyond-spec features discussed" "no beyond-spec topics (rate limit, cache, etc.)"
fi

# ── Summary ───────────────────────────────────────────────────────────

echo -e "\n${BOLD}════════════════════════════════════════${NC}"
echo -e "${BOLD}  Results: ${GREEN}${PASS} passed${NC} / ${RED}${FAIL} failed${NC} (${TOTAL} tests)"
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
echo -e "${BOLD}════════════════════════════════════════${NC}\n"

exit 0
