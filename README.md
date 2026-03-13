# URL Shortener — Onsite Interview

A timed coding exercise where candidates build a URL shortener service, evaluated by an automated black-box test suite.

## How It Works

1. Give the candidate `problem.md` — a deliberately minimal spec
2. Candidate builds the service (any language/framework) on `localhost:8787`
3. Run `./evaluate.sh` to score their implementation out of 100

The evaluation secretly tests dimensions **not mentioned** in the problem (validation, security, HTTP semantics), revealing the candidate's engineering judgment.

## Scoring

| Score | Grade | Interpretation |
|-------|-------|----------------|
| 90–100 | A | Exceptional — strong engineering + AI skills |
| 75–89 | B | Good — solid fundamentals, good AI collaboration |
| 60–74 | C | Acceptable — basics work, missed quality aspects |
| 40–59 | D | Below bar — only basic functionality |
| 0–39 | F | Failing — couldn't get basics working |

## Two Evaluation Dimensions

### `evaluate.sh` — Functional (100 pts)
Black-box tests against the running service: correctness, validation, security, HTTP semantics.

### `evaluate-ai.sh` — AI Collaboration (100 pts)
Analyzes the candidate's Claude Code conversation session (JSONL) to score how effectively they used AI:

| Phase | Pts | What it measures |
|-------|-----|------------------|
| Conversation Structure | 25 | Problem decomposition into focused interactions |
| Prompt Quality | 20 | Clear, specific instructions with spec references |
| Verification & Review | 25 | Testing AI output (curl, read, edge cases) |
| Strategic AI Usage | 20 | Tool diversity, code gen, token efficiency |
| Engineering Depth | 10 | Security, error handling, beyond-spec thinking |

## Requirements

- `bash`, `curl`, `jq`

## Usage

```bash
# evaluate.sh — functional scoring
./evaluate.sh                        # default localhost:8787
./evaluate.sh http://localhost:3000  # custom base URL

# evaluate-ai.sh — AI collaboration scoring
./evaluate-ai.sh                              # interactive picker (CWD)
./evaluate-ai.sh /path/to/candidate/workdir   # interactive picker (workdir)
./evaluate-ai.sh /path/to/session.jsonl       # direct session file
```
