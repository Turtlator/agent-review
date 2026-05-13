#!/usr/bin/env node
// Cross-platform PR helper. Requires only `gh` and Node.js (no PowerShell, no jq).
// Mirrors New-PrReview.ps1 / new-pr-review.sh.

import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync, copyFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';

const args = process.argv.slice(2);

function usage() {
  process.stderr.write(
    `Usage: new-pr-review.mjs --pull-request <url|owner/repo#num|num> [--repo <repo path>] [--workspace <workspace path>] [--slug <slug>] [--force] [--no-diff]\n\n` +
    `Creates a review folder pre-filled from a GitHub pull request. Requires 'gh' (no jq).\n\n` +
    `Workspace resolution: --workspace flag > $AGENT_REVIEW_WORKSPACE env var > $HOME/.agent-review\n`,
  );
}

let prRef = '';
let repo = '';
let workspace = '';
let slug = '';
let force = false;
let noDiff = false;

for (let i = 0; i < args.length; i++) {
  const a = args[i];
  switch (a) {
    case '--pull-request':
    case '--pr':
      prRef = args[++i] || '';
      break;
    case '--repo':
      repo = args[++i] || '';
      break;
    case '--workspace':
      workspace = args[++i] || '';
      break;
    case '--slug':
      slug = args[++i] || '';
      break;
    case '--force':
      force = true;
      break;
    case '--no-diff':
      noDiff = true;
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

if (!prRef) {
  process.stderr.write('--pull-request is required\n');
  usage();
  process.exit(2);
}

function which(cmd) {
  const probe = spawnSync(process.platform === 'win32' ? 'where' : 'which', [cmd], { encoding: 'utf8' });
  return probe.status === 0;
}

if (!which('gh')) {
  process.stderr.write(
    "GitHub CLI 'gh' not found in PATH. Install from https://cli.github.com/ and run 'gh auth login'.\n",
  );
  process.exit(1);
}

if (repo) {
  if (!existsSync(repo)) {
    process.stderr.write(`Repo path does not exist: ${repo}\n`);
    process.exit(1);
  }
  repo = resolve(repo);
}

if (!workspace) {
  workspace = process.env.AGENT_REVIEW_WORKSPACE || join(homedir(), '.agent-review');
}
mkdirSync(workspace, { recursive: true });
workspace = resolve(workspace);

const scriptDir = dirname(fileURLToPath(import.meta.url));
const skillsRoot = resolve(scriptDir, '..');
const toolRoot = resolve(skillsRoot, '..');

function runGh(ghArgs) {
  const opts = { encoding: 'utf8', cwd: repo || undefined, maxBuffer: 64 * 1024 * 1024 };
  return spawnSync('gh', ghArgs, opts);
}

const fields =
  'number,title,body,headRefName,baseRefName,url,author,state,isDraft,files,additions,deletions,headRepositoryOwner,headRepository';
const viewResult = runGh(['pr', 'view', prRef, '--json', fields]);
if (viewResult.status !== 0) {
  if (viewResult.stderr) process.stderr.write(viewResult.stderr);
  process.stderr.write(
    `Failed to fetch PR via 'gh pr view ${prRef}'. Confirm the PR reference is valid and you are authenticated ('gh auth status').\n`,
  );
  process.exit(1);
}

let pr;
try {
  pr = JSON.parse(viewResult.stdout);
} catch (err) {
  process.stderr.write(`Failed to parse 'gh pr view' JSON: ${err.message}\n`);
  process.exit(1);
}

function slugify(text) {
  const lowered = String(text || '').toLowerCase();
  let s = lowered.replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
  if (s.length > 40) s = s.slice(0, 40).replace(/-+$/, '');
  return s;
}

if (!slug) {
  const titleSlug = slugify(pr.title);
  slug = titleSlug ? `pr-${pr.number}-${titleSlug}` : `pr-${pr.number}`;
}

if (!/^[a-zA-Z0-9][a-zA-Z0-9-]*$/.test(slug)) {
  process.stderr.write(`Computed slug is invalid: '${slug}'. Pass --slug to override.\n`);
  process.exit(1);
}

const date = new Date().toISOString().slice(0, 10);
const folderName = `${date}-${slug}`;
const reviewsDir = join(workspace, 'reviews');
const reviewFolder = join(reviewsDir, folderName);
const templateRoot = join(toolRoot, 'templates');

mkdirSync(reviewsDir, { recursive: true });

if (existsSync(reviewFolder) && !force) {
  process.stderr.write(`Review folder already exists: ${reviewFolder}. Use --force to reuse it.\n`);
  process.exit(1);
}
mkdirSync(reviewFolder, { recursive: true });

for (const name of ['resolution.md', 'synthesis.md']) {
  const src = join(templateRoot, name);
  const dst = join(reviewFolder, name);
  if (!existsSync(src)) {
    process.stderr.write(`Missing template: ${src}\n`);
    process.exit(1);
  }
  if (!existsSync(dst) || force) {
    copyFileSync(src, dst);
  }
}

const files = Array.isArray(pr.files) ? pr.files : [];
const fileLines = files.length
  ? files.map((f) => `- ${f.path} (+${f.additions} / -${f.deletions})`)
  : ['- (no files reported by gh pr view)'];
const fileList = fileLines.join('\n');

let repoFull = '(unknown)';
if (pr.url) {
  const m = /github\.com\/([^/]+)\/([^/]+)\/pull\//.exec(pr.url);
  if (m) repoFull = `${m[1]}/${m[2]}`;
}

let headFull = '';
if (pr.headRepository && pr.headRepositoryOwner && pr.headRepositoryOwner.login && pr.headRepository.name) {
  headFull = `${pr.headRepositoryOwner.login}/${pr.headRepository.name}`;
}

const stateLine = pr.isDraft ? `${pr.state} (draft)` : pr.state;
const forkNote = headFull && headFull !== repoFull ? `\nHead repo (fork): ${headFull}` : '';
const repoForRequest = repo || repoFull;

const body = pr.body || '';
const goal = body
  ? `Review GitHub PR #${pr.number}: ${pr.title}.\n\n${body}`
  : `Review GitHub PR #${pr.number}: ${pr.title}. (PR body was empty.)`;

let diffNote = '';
if (!noDiff) {
  const diffResult = runGh(['pr', 'diff', prRef]);
  if (diffResult.status !== 0) {
    process.stderr.write(`Warning: failed to capture PR diff via 'gh pr diff ${prRef}'. Continuing without pr.diff.\n`);
  } else {
    writeFileSync(join(reviewFolder, 'pr.diff'), diffResult.stdout, 'utf8');
    diffNote = `\nPR diff snapshot saved to \`pr.diff\` in this folder (captured at review creation time; re-run \`gh pr diff ${pr.url}\` for the latest).`;
  }
}

const authorLogin = (pr.author && pr.author.login) || '(unknown)';

const content = `# Review: PR #${pr.number} - ${pr.title}

Status: inbox
Repo: ${repoForRequest}
Branch: ${pr.headRefName}
PR: ${pr.url}
Authoring agent: Human
Reviewing agent: Any
Created: ${date}

## Goal

${goal}

## Scope

GitHub PR: ${pr.url}
Base branch: ${pr.baseRefName}
Head branch: ${pr.headRefName}${forkNote}

Changed files (+${pr.additions} / -${pr.deletions} across ${files.length} file(s)):

${fileList}

## Context

- GitHub repo: ${repoFull}
- Author: ${authorLogin}
- State: ${stateLine}
- Inspect the PR diff at \`pr.diff\` for the review snapshot, or run \`gh pr diff ${pr.url}\` for the latest.
- If the reviewing agent needs a local checkout, \`gh pr checkout ${pr.number}\` inside the target repo will fetch the branch.

## Questions

1. <Specific thing to check>
2. <Specific thing to challenge>

## Verification

List commands already run and their outcomes.

\`\`\`text
<command output summary>
\`\`\`

## Notes

This review folder was created from a GitHub PR by the agent-review PR helper (Node).${diffNote}
`;

writeFileSync(join(reviewFolder, 'request.md'), content, 'utf8');
process.stdout.write(`${reviewFolder}\n`);
