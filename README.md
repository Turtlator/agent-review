# Agent Review

Tooling for coordinating code reviews between Codex, Claude Code, and any other local coding agents through a shared filesystem workspace.

The agents do not talk to each other directly. A human operator coordinates the flow by telling one agent when to create a review, telling another agent when to respond, and then deciding what to do with the feedback.

## Basic Idea

Two locations are involved:

- **Tool repo** (this repo): scripts, templates, skill definitions. Same for every user; lives wherever you cloned it (e.g. `C:\dev\agent-review` or `~/src/agent-review`).
- **Workspace**: per-user review data. Default `$HOME/.agent-review`. Never in git.

Each review lives in its own folder under the workspace's `reviews/`:

```text
$HOME/.agent-review/reviews/2026-04-27-example-review/
  request.md
  codex.md
  claude.md
  resolution.md
```

The files have clear ownership:

```text
request.md      The review brief: what changed, what to check, useful context
codex.md        Codex's review notes or response
claude.md       Claude Code's review notes or response
resolution.md   Final decisions, accepted fixes, rejected findings, verification
```

Agents should write to their own response files by default. Codex writes to `codex.md`; Claude Code writes to `claude.md`. Both should only edit the same file if the human operator explicitly asks them to.

## Workspace Location

Resolution order (highest priority first):

1. `--workspace` / `-Workspace` flag on the script or installer
2. `AGENT_REVIEW_WORKSPACE` environment variable
3. Default: `$HOME/.agent-review` (same on Windows, macOS, and Linux)

The installer creates the workspace and its `reviews/` and `archive/` subdirectories on first run, and writes the resolved absolute path into each agent's installed `SKILL.md`.

## Folder Layout

Tool repo:

```text
<tool-root>/
  README.md
  templates/
    review-request.md
    review-response.md
    resolution.md
    synthesis.md
  skills/
    Install-GlobalSkills.ps1
    install-global-skills.sh
    common/
      agent-review-protocol.md
    codex/agent-review/SKILL.md
    claude/agent-review/SKILL.md
    claude/collab-review/SKILL.md
    scripts/
      New-AgentReview.ps1
      new-agent-review.sh
      New-PrReview.ps1
      new-pr-review.sh
      Collab-Review.ps1
      collab-review.sh
```

Workspace (created on first install):

```text
$HOME/.agent-review/
  reviews/
    2026-04-27-example-topic/
      request.md
      codex.md       # Codex's independent review
      claude.md      # Claude's independent review
      synthesis.md   # consolidated view after both reviews + cross-checks
      resolution.md  # human's final decision
  archive/
```

## Typical Flow

1. Ask one agent to create a review request.

Example:

```text
Use the agent-review skill. Create a review handoff for the current branch in C:\dev\EventsAir\nextgen-dev.
```

That agent creates a folder under `reviews/` and fills out `request.md`.

2. Ask the other agent to review it.

Example for Claude Code:

```text
Use the agent-review skill. Read <workspace>/reviews/2026-04-27-example-review/request.md, inspect the repo, and write your review to claude.md.
```

Claude reads the request, checks the code, and writes findings to `claude.md`.

3. Ask Codex to respond to the review.

Example:

```text
Use the agent-review skill. Read Claude's review in <workspace>/reviews/2026-04-27-example-review/claude.md and assess whether the findings are valid.
```

Codex can write its response to `codex.md`, or make code changes if explicitly asked.

4. Decide the outcome.

You or an agent records the final decision in `resolution.md`:

```text
Accepted:
- P1 finding about validation bug. Fixed in FooHandler.cs.

Rejected:
- P2 naming concern. Existing repo convention uses this name.

Verification:
- msbuild NextGen.Slim.sln -nologo -verbosity:quiet -clp:ErrorsOnly passed.
```

5. Archive the review when finished.

Move completed review folders from `reviews/` to `archive/` when they are no longer active.

## Installation

Clone the repo somewhere, then run the installer for your platform.

Windows / PowerShell:

```powershell
<tool-root>\skills\Install-GlobalSkills.ps1
```

macOS / Linux:

```bash
<tool-root>/skills/install-global-skills.sh
```

The installer:

- Creates the workspace at `$HOME/.agent-review` (or `$AGENT_REVIEW_WORKSPACE`, or wherever you pass via `--workspace` / `-Workspace`) with `reviews/` and `archive/` subdirectories.
- Renders each agent's `SKILL.md` with absolute paths to the workspace, protocol, and helper scripts, then installs it to `~/.codex/skills/agent-review/` and `~/.claude/skills/agent-review/`.

Restart any running Codex or Claude Code session after installing or refreshing.

## Starting A Review Manually

Create a new review folder with (Windows / PowerShell):

```powershell
<tool-root>\skills\scripts\New-AgentReview.ps1 -Slug "my-review-topic" -Repo "C:\path\to\repo"
```

macOS / Linux:

```bash
<tool-root>/skills/scripts/new-agent-review.sh --slug "my-review-topic" --repo "/path/to/repo"
```

The script prints the new review folder path. Fill out `request.md`, then point an agent at that folder.

## Reviewing A GitHub Pull Request

To have Claude and Codex collaborate on reviewing a GitHub PR, use the PR helper script. It uses the GitHub CLI (`gh`) to fetch PR metadata and a diff snapshot, then writes a pre-filled review folder so both agents start from the same state.

Windows / PowerShell:

```powershell
<tool-root>\skills\scripts\New-PrReview.ps1 -PullRequest "https://github.com/owner/repo/pull/1234"
```

macOS / Linux (requires `gh` and `jq`):

```bash
<tool-root>/skills/scripts/new-pr-review.sh --pull-request "https://github.com/owner/repo/pull/1234"
```

You can also pass `owner/repo#1234`, or just `1234` along with the `--repo` / `-Repo` flag pointing at a local clone whose default remote resolves the PR.

The script creates `reviews/YYYY-MM-DD-pr-<num>-<title-slug>/` containing:

- `request.md` — pre-filled with title, PR body, base/head branches, author, state, and the changed-file list
- `pr.diff` — diff snapshot at creation time (the source of truth for what is being reviewed)
- `resolution.md` — empty template, ready for the final decision

Prerequisites:

- GitHub CLI installed (`gh --version`) and authenticated (`gh auth login`) with access to the PR's repo
- On macOS/Linux, `jq` (e.g. `brew install jq`)

The script only pulls data from GitHub — it does **not** post reviews back to the PR. If you want findings on the PR itself, paste from `claude.md` / `codex.md` or run `gh pr comment`.

### Collaborative PR Review (Asymmetric: Initiator + Requested)

When you want both Codex and Claude to review the same PR and reconcile findings, run a four-step asymmetric flow with one initiator and one requested reviewer. Full protocol in `skills/common/agent-review-protocol.md`.

#### From inside Claude Code (slash command)

If you are in a Claude Code session, the simplest path is:

```text
/collab-review https://github.com/owner/repo/pull/1234
```

This invokes the `collab-review` skill installed under `~/.claude/skills/collab-review/`. The current Claude session is the initiator - you watch Phase 1 + 4 happen live in chat - and it bashes to `codex exec` for Codex's phases. Codex's review is started in the background so phase 1 + 2 run concurrently.

#### From a terminal (orchestrator script)

A single command runs all four steps headlessly, with steps 1 and 2 in parallel:

Windows / PowerShell:

```powershell
<tool-root>\skills\scripts\Collab-Review.ps1 -PullRequest "https://github.com/owner/repo/pull/1234" [-Initiator claude]
```

macOS / Linux:

```bash
<tool-root>/skills/scripts/collab-review.sh --pull-request "https://github.com/owner/repo/pull/1234" [--initiator claude]
```

Requires `claude` and `codex` CLIs in PATH (plus `gh`/`jq` for the PR fetch). Each phase's log is written to `<review-folder>/.collab/phaseN-<agent>.log` for debugging. Add `--unsafe` / `-Unsafe` for true unattended runs (passes `--dangerously-skip-permissions` to Claude and `--dangerously-bypass-approvals-and-sandbox` to Codex).

#### Manual (for stepping through or for non-PR reviews)

**Step 1 + 2 — Both review independently** (parallel). Each agent reads `request.md` + `pr.diff` and writes to its own file. The "do not read..." line matters — without it the second reviewer anchors on the first.

```text
Use the agent-review skill. Read <review-folder>/request.md and pr.diff. Write your independent review to claude.md. Do not read codex.md.
```

```text
Use the agent-review skill. Read <review-folder>/request.md and pr.diff. Write your independent review to codex.md. Do not read claude.md.
```

**Step 3 — Requested cross-checks initiator.** Only the requested agent does this. Append a `## Cross-check` section to their own file (agreed / disagreed / they caught I missed / I still stand by).

```text
Use the agent-review skill. Read claude.md in <review-folder>. Append a "## Cross-check (vs claude)" section to codex.md per the protocol.
```

**Step 4 — Initiator synthesizes.**

```text
Use the agent-review skill. Read claude.md (your own review) and codex.md (their independent review plus their cross-check of yours). Write the consolidated synthesis to synthesis.md per the protocol: confirmed / disputed / single-source.
```

Then record your final call in `resolution.md` as usual.

## Using The Skill

For either Codex or Claude Code, start with:

```text
Use the agent-review skill.
```

Then tell it which review folder to read or what review to create. The installed skill tells the agent where the shared protocol is, which file it should write to, and how to structure the review.

Examples:

```text
Use the agent-review skill. Create a new review handoff for this repo about the changes on the current branch.
```

```text
Use the agent-review skill. Read <workspace>/reviews/2026-04-27-example-review/request.md and write Codex's response.
```

```text
Use the agent-review skill. Read <workspace>/reviews/2026-04-27-example-review/request.md and write Claude's response to claude.md.
```

Restart Codex or Claude Code after installing or changing global skills if the agent does not discover the skill immediately.

## Review Protocol

1. Create a new dated folder under `reviews/` for each review.
2. Copy `templates/review-request.md` into the review folder as `request.md`.
3. Ask the reviewing agent to read `request.md` and write its response to its own file, such as `codex.md` or `claude.md`.
4. Prefer appending timestamped updates instead of rewriting prior content.
5. Record accepted decisions and follow-up work in `resolution.md`.
6. Move completed review folders to `archive/` when they are no longer active.

## Rules

- Use absolute repo paths so agents can work from any current directory.
- Do not store secrets, tokens, credentials, private customer data, or large logs here.
- Keep review requests specific: include files, commits, commands, risks, and the exact questions to answer.
- Findings should include severity, file path, line number when known, impact, and suggested fix.
- The human operator controls orchestration. Agents should not assume another agent has finished unless the review files show that state clearly.
