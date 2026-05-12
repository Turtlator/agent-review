# Agent Review Protocol

Use this protocol when coordinating code reviews through the shared agent review workspace between Codex, Claude Code, and a human operator.

## Workspace

The workspace (per-user data) is separate from the tool (scripts + templates). Use the concrete `Workspace root` value from the installed `agent-review` skill that loaded this protocol.

Important paths inside the workspace:

- `<workspace>/reviews` - active review folders
- `<workspace>/archive` - completed review folders

Templates and the protocol live in the tool repo (its path is provided as `Tool root` in the installed skill). Agents do not normally read templates directly - the helper scripts copy them in when creating a new review.

Use the host operating system's native path separators when running shell commands. Markdown examples use forward slashes because both agents can read them and they are portable in most shells.

## Core Rules

- Treat the human operator as the orchestrator. Do not wait on, message, or assume another agent is active unless the user explicitly says so.
- Use one folder per review under `reviews/`, named with `YYYY-MM-DD-short-topic`.
- Keep request, response, and resolution files separate unless the user asks for a different shape.
- Prefer appending timestamped sections over rewriting another participant's content.
- Use absolute repo paths, branch names, commit hashes, commands, and exact file references.
- Do not store secrets, tokens, credentials, private customer data, or large logs in the review workspace.
- If you use facts from a review file, cite the path and section in your response.

## Standard Review Folder

```text
<workspace>/reviews/YYYY-MM-DD-short-topic/
  request.md
  codex.md
  claude.md
  resolution.md
```

Use `codex.md` for Codex output and `claude.md` for Claude output. If another participant is involved, use a clear lowercase filename such as `human.md` or `gemini.md`.

## Status Values

Use these values consistently in markdown front matter or top-level fields:

- `inbox` - request exists but no review has started
- `active` - an agent is currently reviewing or responding
- `answered` - review response is ready for the human operator
- `needs-info` - reviewer needs clarification before continuing
- `resolved` - decisions and follow-up work are recorded
- `archived` - review folder has moved to `archive/`

## Creating a Review Request

Prefer the helper script `New-AgentReview.ps1` / `new-agent-review.sh` (or `New-PrReview.ps1` / `new-pr-review.sh` for a GitHub PR) - they create the folder, copy templates, and pre-fill metadata. Only hand-build the folder if you have a reason.

Manual steps if needed:

1. Create a dated folder under `<workspace>/reviews/`.
2. Copy `<tool-root>/templates/review-request.md` to `request.md`.
3. Fill in goal, scope, context, questions, and verification.
4. Create an empty `resolution.md` from `<tool-root>/templates/resolution.md` if it does not exist.
5. Tell the next agent exactly which review folder to read.

The request should answer:

- What repo and branch are involved?
- What changed?
- What should the reviewer focus on?
- What commands have already been run?
- What risks or design concerns are known?

## GitHub PR Reviews

When the change under review is a GitHub pull request, prefer the helper script over a hand-crafted folder. It pulls PR metadata and a diff snapshot via `gh` so both agents see the same starting state.

The installed skill provides absolute script paths. The patterns below use `<tool-root>` for that location:

Windows / PowerShell:

```powershell
<tool-root>/skills/scripts/New-PrReview.ps1 -PullRequest <url-or-owner/repo#num-or-number> [-Repo <local repo path>]
```

macOS / Linux (requires `gh` and `jq`):

```bash
<tool-root>/skills/scripts/new-pr-review.sh --pull-request <url-or-owner/repo#num-or-number> [--repo <local repo path>]
```

- The `--pull-request` (or `-PullRequest`) arg accepts the PR URL, `owner/repo#number`, or just `number` when `--repo` points at a local clone whose default remote resolves the PR.
- The script writes a dated folder named `pr-<num>-<slug>` containing `request.md`, `resolution.md`, and `pr.diff` (the diff snapshot at creation time).
- `request.md` is pre-filled with title, body, base/head branches, author, state, file list, and the PR URL. Reviewers should treat `pr.diff` as the source of truth for what is being reviewed; if the PR has moved on, re-run `gh pr diff <pr>` from the target repo.
- For deeper inspection a reviewer can run `gh pr checkout <num>` inside the target repo to get the branch locally.
- The script does **not** post anything back to GitHub. Agent reviews stay in `claude.md` / `codex.md`. If the human operator wants findings on the PR itself, they paste or `gh pr comment` from the relevant review file.

## Responding to a Review

1. Read `request.md` first.
2. Read any existing agent response files only if they are relevant to the user's instruction.
3. Inspect the target repo directly for claims that affect correctness.
4. Write or append to your own response file only.
5. Lead with findings ordered by severity, then questions, then verification.
6. Mark your response status as `answered` unless blocked.

Finding format:

```md
### P1: <finding title>

- File: <absolute path>
- Line: <line number or unknown>
- Impact: <what can go wrong>
- Evidence: <specific code, behavior, or command result>
- Recommendation: <specific fix or next step>
```

Severity guide:

- `P0` - data loss, security issue, production outage, or corrupting behavior
- `P1` - likely user-visible bug or major regression
- `P2` - correctness, maintainability, or test risk worth fixing before merge
- `P3` - minor issue, cleanup, or optional improvement

## Collaborative Review (Both Agents)

When the human operator wants both Codex and Claude to review the same change and reconcile findings, run a four-step asymmetric flow with one initiator and one requested reviewer. This applies to any review (local branch or GitHub PR) but is the default for PR reviews created via the PR helper script.

Role assignment:

- **Initiator** - the agent the operator turned to first. Performs its own independent review, then later synthesizes everything.
- **Requested** - the other agent. Performs its own independent review, then cross-checks the initiator's findings.

### Step 1 - Initiator Independent Review (parallel with step 2)

Initiator reviews `request.md` (and `pr.diff` if present) without reading the requested agent's file. Writes findings to its own file (`claude.md` or `codex.md`).

### Step 2 - Requested Independent Review (parallel with step 1)

Same as step 1 but for the requested agent, writing to its own file. Independence is the whole point - skipping it lets either reviewer anchor on the other's framing.

Example prompts for steps 1 + 2:

```text
Use the agent-review skill. Read <workspace>/reviews/<folder>/request.md and pr.diff. Write your independent review to claude.md. Do not read codex.md.
```

```text
Use the agent-review skill. Read <workspace>/reviews/<folder>/request.md and pr.diff. Write your independent review to codex.md. Do not read claude.md.
```

### Step 3 - Requested Cross-Checks Initiator

Once both independent reviews exist, the requested agent reads the initiator's file and appends a `## Cross-check` section to *its own* file. The requested agent still only edits its own file.

Cross-check section format:

```md
## Cross-check (vs <initiator>)

### Agreed
- <ref to initiator's finding>: <why I agree>

### Disagreed
- <ref to initiator's finding>: <why I disagree, with evidence>

### They caught, I missed
- <new finding from initiator>: <my read on it>

### I still stand by
- <my findings the initiator did not raise>: <why these still apply>
```

### Step 4 - Initiator Synthesizes

The initiator reads its own file plus the requested agent's full file (independent review + cross-check section) and writes `synthesis.md`. Three buckets:

- **Confirmed** - both reviewers flagged it, OR initiator flagged and requested agreed in cross-check. High signal.
- **Disputed** - one flagged, the other disagreed. Include both sides' reasoning.
- **Single-source** - only one reviewer flagged it. Lower signal, still worth a sanity check.

Synthesis is agent-produced and is not the final call. The human operator still records the binding decision in `resolution.md`.

### Orchestration

The four steps can be driven manually by prompting each agent in order, or automated with the orchestrator script which invokes each agent's CLI headlessly:

```text
<tool-root>/skills/scripts/collab-review.sh --pull-request <ref> [--initiator claude|codex]
```

PowerShell mirror at `<tool-root>/skills/scripts/Collab-Review.ps1`. Steps 1 and 2 run in parallel; steps 3 and 4 are sequential.

## Resolving a Review

Use `resolution.md` to record the human decision and final state:

- Accepted findings
- Rejected findings with reason
- Deferred work
- Follow-up commits or files changed
- Final verification commands

Move the folder from `reviews/` to `archive/` only when the human operator asks or the review is clearly complete.

## Agent-Specific Notes

Codex:

- Use the code review stance when asked to review: findings first, concise summary second.
- Do not emit GitHub-style inline comments into review files unless the user asks.
- Follow the current repo's `AGENTS.md` when inspecting or changing code.

Claude Code:

- Use the same review protocol and write to `claude.md` by default.
- Restart Claude Code after installing or changing global skills if the skill is not discovered.
- Follow the current repo's `CLAUDE.md` or other local instructions when inspecting or changing code.

