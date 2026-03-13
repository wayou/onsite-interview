#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const { execSync, execFileSync } = require('child_process');
const readline = require('readline');

// ── Colors ──────────────────────────────────────────────────────────
const BOLD = '\x1b[1m';
const NC = '\x1b[0m';

// ── Preflight ───────────────────────────────────────────────────────
function preflight() {
  try {
    execSync('which claude', { stdio: 'ignore' });
  } catch {
    console.error("Error: 'claude' CLI not found. Install Claude Code first.");
    console.error('  https://docs.anthropic.com/en/docs/claude-code');
    process.exit(1);
  }
}

// ── Arg parsing ─────────────────────────────────────────────────────
function parseArgs() {
  const args = process.argv.slice(2);
  let model = 'sonnet';
  const rest = [];

  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--model' && i + 1 < args.length) {
      model = args[++i];
    } else {
      rest.push(args[i]);
    }
  }
  return { model, rest };
}

// ── Session discovery ───────────────────────────────────────────────
function getProjectDir(workdir) {
  const resolved = path.resolve(workdir);
  const encoded = resolved.replace(/\//g, '-');
  return path.join(os.homedir(), '.claude', 'projects', encoded);
}

function listSessionFiles(projectDir) {
  if (!fs.existsSync(projectDir)) {
    console.error(`Error: No Claude Code project found at ${projectDir}`);
    process.exit(1);
  }

  const files = fs.readdirSync(projectDir)
    .filter(f => f.endsWith('.jsonl'))
    .map(f => {
      const full = path.join(projectDir, f);
      const stat = fs.statSync(full);
      return { path: full, name: f, mtime: stat.mtimeMs, size: stat.size };
    })
    .sort((a, b) => b.mtime - a.mtime);

  if (files.length === 0) {
    console.error(`Error: No .jsonl session files found in ${projectDir}`);
    process.exit(1);
  }
  return files;
}

function formatSize(bytes) {
  if (bytes < 1024) return bytes + 'B';
  const kb = bytes / 1024;
  if (kb < 1024) return Math.round(kb) + 'K';
  return (kb / 1024).toFixed(1) + 'M';
}

function formatDate(ms) {
  const d = new Date(ms);
  const pad = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function truncName(name, max) {
  if (name.length <= max) return name;
  return name.slice(0, 16) + '...' + name.slice(-12);
}

async function promptUser(question) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stderr });
  return new Promise(resolve => {
    rl.question(question, answer => {
      rl.close();
      resolve(answer.trim());
    });
  });
}

async function resolveSessionFile(workdir) {
  const projectDir = getProjectDir(workdir);
  const files = listSessionFiles(projectDir);

  console.log('');
  console.log('Available sessions (newest first):');
  files.forEach((f, i) => {
    const display = truncName(f.name, 40);
    console.log(`  ${i + 1}) ${formatDate(f.mtime)}  ${formatSize(f.size).padStart(4)}  ${display}`);
  });

  const answer = await promptUser('Select session [1]: ');
  const choice = answer === '' ? 1 : parseInt(answer, 10);

  if (isNaN(choice) || choice < 1 || choice > files.length) {
    console.error('Error: Invalid selection');
    process.exit(1);
  }
  return files[choice - 1].path;
}

// ── Condensation ────────────────────────────────────────────────────
function trunc(str, n) {
  if (typeof str !== 'string') return '';
  return str.length > n ? str.slice(0, n) + ' [truncated]' : str;
}

function extractTexts(msg) {
  const content = msg.message?.content;
  if (typeof content === 'string') return [content];
  if (Array.isArray(content)) {
    return content.filter(b => b.type === 'text').map(b => b.text);
  }
  return [];
}

function extractToolUses(msg) {
  const content = msg.message?.content;
  if (!Array.isArray(content)) return [];
  return content.filter(b => b.type === 'tool_use');
}

function extractToolResults(msg) {
  const content = msg.message?.content;
  if (!Array.isArray(content)) return [];
  return content.filter(b => b.type === 'tool_result');
}

function toolDetail(tool) {
  const input = tool.input || {};
  switch (tool.name) {
    case 'Bash': return trunc(input.command || '', 200);
    case 'Write': return `file: ${input.file_path || 'unknown'} [${(input.content || '').length} chars]`;
    case 'Edit': return `file: ${input.file_path || 'unknown'} old: ${trunc(input.old_string || '', 80)} -> new: ${trunc(input.new_string || '', 80)}`;
    case 'Read': return `file: ${input.file_path || 'unknown'}`;
    case 'Grep': return `pattern: ${input.pattern || 'unknown'}`;
    case 'Glob': return `pattern: ${input.pattern || 'unknown'}`;
    default: return trunc(JSON.stringify(input), 150);
  }
}

function resultSummary(result) {
  if (typeof result.content === 'string') return trunc(result.content, 150);
  if (Array.isArray(result.content)) {
    return trunc(
      result.content.filter(b => b.type === 'text').map(b => b.text).join(' '),
      150
    );
  }
  return '';
}

function condenseSession(sessionFile) {
  const raw = fs.readFileSync(sessionFile, 'utf8');
  const records = raw.trim().split('\n').map(line => {
    try { return JSON.parse(line); } catch { return null; }
  }).filter(Boolean);

  const condensed = records
    .filter(r => (r.type === 'user' || r.type === 'assistant') && !r.isMeta)
    .map(r => {
      const isUser = r.type === 'user';
      const texts = extractTexts(r).map(t => isUser ? t : trunc(t, 300));
      const tools = extractToolUses(r).map(t => ({ name: t.name, detail: toolDetail(t) }));
      const results = extractToolResults(r).map(t => ({ summary: resultSummary(t) }));
      return {
        role: r.type,
        ts: r.timestamp,
        texts,
        tools,
        results,
        usage: r.message?.usage,
      };
    })
    .filter(r => r.texts.length > 0 || r.tools.length > 0 || r.results.length > 0);

  let json = JSON.stringify(condensed);

  // Safety valve: aggressive truncation if too large
  if (json.length > 150000) {
    console.log(`Condensed output too large (${json.length} chars), applying aggressive truncation...`);
    const aggressive = records
      .filter(r => (r.type === 'user' || r.type === 'assistant') && !r.isMeta)
      .map(r => ({
        role: r.type,
        texts: extractTexts(r).map(t => trunc(t, 100)),
        tools: extractToolUses(r).map(t => t.name),
      }))
      .filter(r => r.texts.length > 0 || r.tools.length > 0);
    json = JSON.stringify(aggressive);

    if (json.length > 200000) {
      console.error(`Error: Session too large even after aggressive truncation (${json.length} chars).`);
      process.exit(1);
    }
  }

  return json;
}

// ── Prompt & Schema ─────────────────────────────────────────────────
const RUBRIC_PROMPT = `You are evaluating a coding interview candidate's AI collaboration skills. The candidate was asked to build a URL shortening service using Claude Code (an AI coding assistant). Below is a condensed transcript of their Claude Code session.

Evaluate the candidate across these 5 phases using the rubric below. For each criterion, assign a score and provide a brief reason.

## Rubric

### Phase 1: Conversation Structure (25 pts)
- **Reasonable prompt count** (8 pts): 3-20 prompts suggests iterative collaboration. 1-2 = one-shot dump; >30 = excessive micro-managing.
- **Not excessively chatty** (4 pts): <=30 prompts. More suggests inability to form coherent requests.
- **Multi-turn iteration** (8 pts): >=3 back-and-forth turns show the candidate refined and iterated, not just fire-and-forget.
- **Session not trivially short** (5 pts): Session should span at least a few minutes, showing thoughtful engagement.

### Phase 2: Prompt Quality (20 pts)
- **Thoughtful prompts** (6 pts): Prompts should be specific, clear, and show engineering thinking — not vague ("make it work") or formulaic ("now add tests").
- **References spec/requirements** (5 pts): Candidate should reference specific requirements (URLs, ports, behaviors) from the problem statement.
- **Problem decomposition** (5 pts): Candidate breaks the problem into logical steps (setup, core logic, error handling, testing) rather than asking for everything at once.
- **Not verbatim spec paste** (4 pts): Candidate should paraphrase/decompose the spec, not just paste it wholesale.

### Phase 3: Verification & Review (25 pts)
- **Tested the service** (8 pts): Candidate ran curl commands or similar to verify the service works.
- **Multiple verification attempts** (5 pts): >=2 distinct verification actions (different endpoints, error cases, etc.).
- **Reviewed generated code** (5 pts): Candidate read/reviewed the generated code rather than blindly accepting it.
- **Ran automated tests** (4 pts): Candidate ran test suites (go test, npm test, etc.) or asked for tests to be written and run.
- **Tested edge cases** (3 pts): Candidate tested error conditions, invalid inputs, or boundary cases.

### Phase 4: Strategic AI Usage (20 pts)
- **Tool diversity** (6 pts): Used >=3 different tools (Bash, Read, Write, Edit, Grep, etc.) showing understanding of AI capabilities.
- **Code generation** (5 pts): AI was used to write/edit code (Write or Edit tools used).
- **Token efficiency** (5 pts): Reasonable token usage (<500k total). Excessive tokens suggest unproductive loops.
- **Iterative refinement** (4 pts): Multiple turns of refining code/approach, not just a single prompt.

### Phase 5: Engineering Depth (10 pts)
- **Security/validation awareness** (4 pts): Discussion of input validation, URL sanitization, or security concerns.
- **Error handling** (3 pts): Discussion or implementation of error handling, status codes, edge cases.
- **Beyond-spec thinking** (3 pts): Candidate considered aspects beyond the basic spec (rate limiting, caching, analytics, concurrent access, etc.).

## Session Transcript

<session>
`;


// ── LLM Call ────────────────────────────────────────────────────────
function callClaude(prompt, model) {
  const maxAttempts = 2;

  // Unset CLAUDECODE env var to allow nested claude calls
  const env = { ...process.env };
  delete env.CLAUDECODE;

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      const result = execFileSync('claude', [
        '--print',
        '--model', model,
      ], {
        input: prompt,
        encoding: 'utf8',
        maxBuffer: 10 * 1024 * 1024,
        env,
      });
      return result;
    } catch (err) {
      if (attempt < maxAttempts) {
        console.error(`LLM call failed (attempt ${attempt}/${maxAttempts}), retrying...`);
      }
    }
  }
  return null;
}


// ── Main ────────────────────────────────────────────────────────────
async function main() {
  preflight();

  const { model, rest } = parseArgs();
  let sessionFile;

  if (rest.length === 0) {
    sessionFile = await resolveSessionFile(process.cwd());
  } else if (rest[0].endsWith('.jsonl')) {
    sessionFile = rest[0];
  } else if (fs.existsSync(rest[0]) && fs.statSync(rest[0]).isDirectory()) {
    sessionFile = await resolveSessionFile(rest[0]);
  } else {
    console.error(`Usage: ${path.basename(process.argv[1])} [--model sonnet|opus] [session.jsonl | workdir]`);
    process.exit(1);
  }

  // Validate
  if (!fs.existsSync(sessionFile)) {
    console.error(`Error: Session file not found: ${sessionFile}`);
    process.exit(1);
  }
  if (fs.statSync(sessionFile).size === 0) {
    console.error(`Error: Session file is empty: ${sessionFile}`);
    process.exit(1);
  }

  console.log('');
  console.log(`Analyzing (LLM): ${path.basename(sessionFile)}`);
  console.log(`Model: ${model}`);
  console.log('');

  // Stage 1: Condense
  console.log(`${BOLD}Condensing session transcript...${NC}`);
  const condensed = condenseSession(sessionFile);
  console.log(`Condensed to ${condensed.length} chars`);

  // Stage 2: Build prompt
  const prompt = RUBRIC_PROMPT + condensed + '\n</session>\n\nScore each criterion and provide your evaluation. Format the output nicely with scores per criterion, phase subtotals, a final total score out of 100, a letter grade (A/B/C/D/F), a summary, strengths, and areas for improvement.\n\nIMPORTANT: Write your entire evaluation report in Simplified Chinese (zh-CN).';

  // Log the full prompt to file for debugging
  const logFile = sessionFile.replace(/\.jsonl$/, '-llm-prompt.log');
  fs.writeFileSync(logFile, prompt, 'utf8');
  console.log(`Full prompt logged to: ${logFile}`);

  // Stage 3: Call LLM and display result directly
  console.log(`${BOLD}Calling Claude (${model}) for evaluation...${NC}`);
  console.log('');

  const result = callClaude(prompt, model);
  if (!result) {
    console.error(`Error: LLM evaluation failed after 2 attempts.`);
    process.exit(1);
  }

  // Just display Claude's evaluation directly
  console.log(result);
}

main().catch(err => {
  console.error(err.message);
  process.exit(1);
});
