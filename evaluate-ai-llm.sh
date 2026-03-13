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

  [.[] | select(.type == "user" or .type == "assistant") | select(.isMeta | not) |
  . as $msg |
  {
    role: .type,
    ts: .timestamp,
    texts: [extract_texts[] | if $msg.type == "user" then . else trunc(300) end],
    tools: [extract_tool_uses[] | {name: .name, detail: tool_detail}],
    results: [extract_tool_results[] | {summary: result_summary}],
    usage: .message.usage
  }
  # Drop entries with no useful content
  | select((.texts | length > 0) or (.tools | length > 0) or (.results | length > 0))
  ]
') || {
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

    [.[] | select(.type == "user" or .type == "assistant") | select(.isMeta | not) |
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

PROMPT="${PROMPT}"$'\n'"${CONDENSED}"$'\n'"</session>"$'\n\n'"Score each criterion and provide your evaluation."

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

  LLM_OUTPUT=$(printf '%s' "$PROMPT" | claude --print --output-format json --json-schema "$SCHEMA" --model "$MODEL" 2>/dev/null) && break

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
