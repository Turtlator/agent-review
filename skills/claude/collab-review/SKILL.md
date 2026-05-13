---
name: collab-review
description: Run a collaborative GitHub PR review with Codex. This Claude session is the initiator (reviews independently, then synthesizes); Codex is the requested reviewer (reviews independently, then cross-checks). Use when the user types /collab-review or asks for both Claude and Codex to review a PR together.
---

# Collaborative PR Review

Run the four-step asymmetric collaborative review flow with this Claude session as initiator and Codex as the requested reviewer. The full protocol is at `{{PROTOCOL_PATH}}` - read it before starting if you haven't already.

Workspace root: `{{AGENT_REVIEW_WORKSPACE}}`
Tool root: `{{AGENT_REVIEW_TOOL_ROOT}}`

## Input

The user invokes this as `/collab-review <pr-ref>` where `<pr-ref>` is one of:

- A GitHub PR URL: `https://github.com/owner/repo/pull/123`
- `owner/repo#123`
- A bare number `123` (only when the user's cwd is a local clone of the PR's repo)

If no PR ref is provided, ask the user for one before proceeding.

## Flow

### Step 0 - Create the review folder

Use the PR helper to fetch metadata and create the folder. The Node helper is the cross-platform default — it only needs `gh` and Node.js, so it works regardless of the user's PowerShell or `jq` situation:

```text
Cross-platform (recommended):
  node {{NEW_PR_REVIEW_MJS}} --pull-request "<pr-ref>"
```

Fall back to a shell-specific variant only if the user explicitly asks or if Node is not available:

```text
Windows PowerShell:
  {{NEW_PR_REVIEW_PS1}} -PullRequest "<pr-ref>"

macOS/Linux bash (requires `jq`):
  {{NEW_PR_REVIEW_SH}} --pull-request "<pr-ref>"
```

The helper prints the review folder path on stdout. Capture it - you will need it for every later step. The folder will already contain `request.md`, `pr.diff`, empty `resolution.md`, and empty `synthesis.md`.

### Step 1 + 2 - Independent reviews (parallel)

Kick off Codex's independent review **in the background** via Bash with `run_in_background: true`:

```text
codex exec --sandbox workspace-write --skip-git-repo-check -C "<review-folder>" "Use the agent-review skill. Read request.md and pr.diff in the current directory. Write your independent review to codex.md in the current directory. Do not read claude.md."
```

You will receive a task ID for the background job. Codex now runs concurrently.

**Immediately**, while Codex is working, do your own independent review:

- Read `<review-folder>/request.md` and `<review-folder>/pr.diff`
- Apply the agent-review protocol's finding format (severity-led, file/line, impact, evidence, recommendation)
- Write your findings to `<review-folder>/claude.md`
- **Do not** read `codex.md` - it is being written by Codex right now and your review must be independent

When your own Phase 1 is done, if you have not yet received the "background task complete" notification for Codex, wait for it. Do not poll or sleep; the notification arrives on its own.

Once Codex's task completes, verify `codex.md` exists and is non-empty before proceeding. If Codex's job failed, surface the error to the user and stop.

### Step 3 - Codex cross-checks your review

Run Codex in the **foreground** (no `run_in_background`):

```text
codex exec --sandbox workspace-write --skip-git-repo-check -C "<review-folder>" "Use the agent-review skill. Read claude.md in the current directory. Append a '## Cross-check (vs claude)' section to codex.md per the protocol with four subsections: Agreed, Disagreed, They caught I missed, I still stand by. Only edit codex.md."
```

Verify `codex.md` now contains a `## Cross-check` section before continuing.

### Step 4 - Synthesize

Read:

- `<review-folder>/claude.md` (your own independent review)
- `<review-folder>/codex.md` (Codex's independent review + cross-check of your review)

Write `<review-folder>/synthesis.md` per the protocol's three buckets:

- **Confirmed** - both reviewers flagged it, or one flagged and the other explicitly agreed in cross-check
- **Disputed** - one flagged, the other rejected it (include both sides' reasoning)
- **Single-source** - only one reviewer raised it (lower signal, still worth a sanity check)

### Step 5 (optional) - Post findings back to the PR

If the user asks for the synthesis to land on the PR itself (rather than copying by hand), run:

```text
node {{POST_PR_REVIEW_MJS}} --review "<review-folder>" --event COMMENT
```

Defaults:

- `--body` defaults to `<review-folder>/synthesis.md`.
- `--event` defaults to `COMMENT`. Use `APPROVE` or `REQUEST_CHANGES` only when the user explicitly says so.
- Inline comments come from `<review-folder>/comments.json` if that file exists; otherwise the post is a top-level review body only.

To include inline comments, write `comments.json` in the review folder before posting. Schema is a JSON array of:

```json
[
  { "path": "src/foo.ts", "line": 42, "body": "Comment text", "side": "RIGHT" }
]
```

`side` defaults to `RIGHT` (the new file). For a multi-line range, add `start_line` and optionally `start_side`. Always derive `path` and `line` from `pr.diff` so the line numbers match what GitHub expects.

The script reads the PR URL from `request.md`, resolves the current head SHA via `gh pr view`, and POSTs to `repos/<owner>/<repo>/pulls/<num>/reviews` (no leading slash — Git Bash on Windows otherwise rewrites it to a filesystem path).

Use `--dry-run` to print the payload without posting.

## Reporting back to the user

When all four steps complete, tell the user:

1. The review folder path
2. A one-line count summary, e.g. "Synthesis: 5 confirmed, 1 disputed, 3 single-source"
3. Remind them the final call goes in `resolution.md` and they should read `synthesis.md` first
4. If you ran Step 5, include the URL gh returned for the posted review

## Failure handling

If any step fails:

- Stop. Do not attempt later steps.
- Tell the user which step failed and quote the relevant error from the Bash output.
- Leave the partial state in the review folder for inspection.

If Codex's CLI is not found, point the user at the PATH troubleshooting and stop early.
