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

## Requirements

- `bash`, `curl`, `jq`

## Usage

```bash
# Default (localhost:8787)
./evaluate.sh

# Custom base URL
./evaluate.sh http://localhost:3000
```
