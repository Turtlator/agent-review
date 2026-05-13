#!/usr/bin/env node
// Post a synthesised review back to a GitHub PR.
//
// Reads:
//   <review-folder>/synthesis.md   -- review body (or the file named by --body)
//   <review-folder>/comments.json  -- optional inline comments (skipped if absent)
//
// comments.json schema (array of objects):
//   [
//     {
//       "path": "src/foo.ts",          // required, repo-relative
//       "line": 42,                     // required line in the new file
//       "side": "RIGHT" | "LEFT",      // optional, default RIGHT
//       "start_line": 40,               // optional, multi-line range
//       "start_side": "RIGHT" | "LEFT", // optional
//       "body": "Comment text"          // required
//     }
//   ]
//
// Endpoint is invoked WITHOUT a leading slash to avoid Git Bash / MSYS path
// mangling on Windows (gh prints a hint about this; we just always omit it).

import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

function usage() {
  process.stderr.write(
    `Usage: post-pr-review.mjs --review <review-folder> [--body <md-file>] [--event APPROVE|COMMENT|REQUEST_CHANGES] [--comments <json-file>] [--dry-run]\n\n` +
    `Posts a synthesised review back to the PR referenced by <review-folder>/request.md.\n` +
    `Default body is synthesis.md; default event is COMMENT; comments default to comments.json if present.\n`,
  );
}

const args = process.argv.slice(2);
let reviewFolder = '';
let bodyFile = '';
let event = 'COMMENT';
let commentsFile = '';
let dryRun = false;

for (let i = 0; i < args.length; i++) {
  const a = args[i];
  switch (a) {
    case '--review':
    case '--review-folder':
      reviewFolder = args[++i] || '';
      break;
    case '--body':
      bodyFile = args[++i] || '';
      break;
    case '--event':
      event = (args[++i] || '').toUpperCase();
      break;
    case '--comments':
      commentsFile = args[++i] || '';
      break;
    case '--dry-run':
      dryRun = true;
      break;
    case '-h':
    case '--help':
      usage();
      process.exit(0);
      break;
    default:
      process.stderr.write(`Unknown argument: ${a}\n`);
      usage();
      process.exit(2);
  }
}

if (!reviewFolder) {
  process.stderr.write('--review is required\n');
  usage();
  process.exit(2);
}
if (!existsSync(reviewFolder)) {
  process.stderr.write(`Review folder does not exist: ${reviewFolder}\n`);
  process.exit(1);
}
if (!['APPROVE', 'COMMENT', 'REQUEST_CHANGES'].includes(event)) {
  process.stderr.write(`--event must be APPROVE, COMMENT, or REQUEST_CHANGES (got '${event}').\n`);
  process.exit(2);
}

function which(cmd) {
  const probe = spawnSync(process.platform === 'win32' ? 'where' : 'which', [cmd], { encoding: 'utf8' });
  return probe.status === 0;
}
if (!which('gh')) {
  process.stderr.write("GitHub CLI 'gh' not found in PATH. Install from https://cli.github.com/ and run 'gh auth login'.\n");
  process.exit(1);
}

const requestPath = join(reviewFolder, 'request.md');
if (!existsSync(requestPath)) {
  process.stderr.write(`Missing request.md in ${reviewFolder}\n`);
  process.exit(1);
}
const requestText = readFileSync(requestPath, 'utf8');

const prMatch = /PR:\s*(\S+)/.exec(requestText);
if (!prMatch) {
  process.stderr.write(`Could not find a 'PR: <url>' line in ${requestPath}\n`);
  process.exit(1);
}
const prUrl = prMatch[1];
const m = /github\.com\/([^/]+)\/([^/]+)\/pull\/(\d+)/.exec(prUrl);
if (!m) {
  process.stderr.write(`PR URL in request.md is not a recognisable GitHub PR URL: ${prUrl}\n`);
  process.exit(1);
}
const owner = m[1];
const repo = m[2];
const prNumber = m[3];

const bodyPath = bodyFile || join(reviewFolder, 'synthesis.md');
if (!existsSync(bodyPath)) {
  process.stderr.write(`Body file does not exist: ${bodyPath}\n`);
  process.exit(1);
}
const body = readFileSync(bodyPath, 'utf8');

let comments = [];
const commentsPath = commentsFile || join(reviewFolder, 'comments.json');
if (existsSync(commentsPath)) {
  try {
    const parsed = JSON.parse(readFileSync(commentsPath, 'utf8'));
    if (!Array.isArray(parsed)) throw new Error('comments file must be a JSON array');
    comments = parsed.map((c, idx) => {
      if (!c || typeof c !== 'object') throw new Error(`comment ${idx} is not an object`);
      if (!c.path || typeof c.path !== 'string') throw new Error(`comment ${idx} missing 'path'`);
      if (typeof c.line !== 'number') throw new Error(`comment ${idx} missing numeric 'line'`);
      if (!c.body || typeof c.body !== 'string') throw new Error(`comment ${idx} missing 'body'`);
      const out = { path: c.path, line: c.line, body: c.body, side: c.side || 'RIGHT' };
      if (typeof c.start_line === 'number') out.start_line = c.start_line;
      if (c.start_side) out.start_side = c.start_side;
      return out;
    });
  } catch (err) {
    process.stderr.write(`Failed to parse ${commentsPath}: ${err.message}\n`);
    process.exit(1);
  }
}

// Resolve commit_id from the PR (required so inline comments anchor to the
// reviewed SHA, not whatever lands on the branch later).
const headSha = spawnSync('gh', ['pr', 'view', prUrl, '--json', 'headRefOid', '-q', '.headRefOid'], { encoding: 'utf8' });
if (headSha.status !== 0) {
  if (headSha.stderr) process.stderr.write(headSha.stderr);
  process.stderr.write(`Failed to resolve head SHA for ${prUrl}\n`);
  process.exit(1);
}
const commitId = headSha.stdout.trim();

const payload = { commit_id: commitId, event, body, comments };

if (dryRun) {
  process.stdout.write(JSON.stringify(payload, null, 2) + '\n');
  process.stdout.write(`Would POST to: repos/${owner}/${repo}/pulls/${prNumber}/reviews\n`);
  process.exit(0);
}

// Write payload to a temp file and feed via --input to avoid argv quoting hell
// on Windows when the body contains Markdown.
const tmp = mkdtempSync(join(tmpdir(), 'agent-review-'));
const payloadPath = join(tmp, 'payload.json');
writeFileSync(payloadPath, JSON.stringify(payload), 'utf8');

// IMPORTANT: no leading slash on the endpoint. Git Bash / MSYS on Windows
// rewrites leading-slash arguments as filesystem paths, which makes gh reject
// the URL. The repos/... form works everywhere.
const endpoint = `repos/${owner}/${repo}/pulls/${prNumber}/reviews`;
const result = spawnSync('gh', ['api', '-X', 'POST', endpoint, '--input', payloadPath], { encoding: 'utf8' });

try {
  rmSync(tmp, { recursive: true, force: true });
} catch {
  // best-effort cleanup
}

if (result.stdout) process.stdout.write(result.stdout);
if (result.stderr) process.stderr.write(result.stderr);
if (result.status !== 0) {
  process.stderr.write(`gh api POST ${endpoint} failed (exit ${result.status}).\n`);
  process.exit(result.status || 1);
}
