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

VERSION="0.6.0"

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
