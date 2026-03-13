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

VERSION="0.2.0"

# ── Usage ────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 [options]

Run both functional and AI collaboration evaluations in one go.

Options:
  -u, --url URL        Base URL for functional tests (default: http://localhost:8787)
  -s, --session FILE   Session JSONL file for AI evaluation
  -w, --workdir DIR    Working directory for session discovery (default: CWD)
  -f, --functional     Run only functional evaluation
  -a, --ai-only        Run only AI collaboration evaluation
  -v, --version        Show version
  -h, --help           Show this help

Examples:
  $0                                         # both evals, defaults
  $0 -u http://localhost:3000                # custom URL, both evals
  $0 -s /path/to/session.jsonl              # both evals, explicit session
  $0 -f                                      # functional only
  $0 -a -s /path/to/session.jsonl           # AI only
EOF
  exit 0
}

# ── Defaults ─────────────────────────────────────────────────────────
BASE_URL="http://localhost:8787"
SESSION_ARG=""
RUN_FUNCTIONAL=true
RUN_AI=true

# ── Parse args ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--url)       BASE_URL="$2"; shift 2 ;;
    -s|--session)   SESSION_ARG="$2"; shift 2 ;;
    -w|--workdir)   SESSION_ARG="$2"; shift 2 ;;
    -f|--functional) RUN_FUNCTIONAL=true; RUN_AI=false; shift ;;
    -a|--ai-only)   RUN_AI=true; RUN_FUNCTIONAL=false; shift ;;
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
  echo ""
  echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${BLUE}║   AI COLLABORATION (evaluate-ai.sh)      ║${NC}"
  echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════╝${NC}"
  echo ""

  if [[ -n "$SESSION_ARG" ]]; then
    AI_OUTPUT=$("$SCRIPT_DIR/evaluate-ai.sh" "$SESSION_ARG" 2>&1) || true
  else
    # Interactive mode — pass through stdin
    "$SCRIPT_DIR/evaluate-ai.sh"
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
