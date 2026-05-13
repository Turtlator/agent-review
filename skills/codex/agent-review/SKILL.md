---
name: agent-review
description: Coordinate cross-agent code reviews through the shared agent-review workspace. Use when the user asks Codex to create, read, respond to, summarize, or resolve agent review handoffs involving Codex, Claude Code, shared review folders, request.md, codex.md, claude.md, or resolution.md.
---

# Agent Review

Use the shared protocol at `{{PROTOCOL_PATH}}` for all behavior. Read it before creating, updating, or interpreting review handoff files.

Workspace root: `{{AGENT_REVIEW_WORKSPACE}}`
Tool root: `{{AGENT_REVIEW_TOOL_ROOT}}`

## Codex Workflow

1. Read the shared protocol.
2. Locate the review folder the user names, or create one under `{{AGENT_REVIEW_WORKSPACE}}/reviews` if the user asks for a new review.
3. Follow the current repository's `AGENTS.md` and local instructions before reviewing or editing code.
4. Write Codex output to `codex.md` unless the user asks for another file.
5. Preserve other participants' files. Append timestamped updates when adding to an existing Codex response.
6. In chat, summarize the action taken and reference the review file path.

## Common Commands

Create a review folder from templates:

```powershell
{{NEW_REVIEW_PS1}} -Slug "short-topic" -Repo "<absolute repo path>"
```

On macOS/Linux:

```bash
{{NEW_REVIEW_SH}} --slug "short-topic" --repo "<absolute repo path>"
```

Create a review folder from a GitHub pull request (pulls PR metadata and diff via `gh`). The Node helper is the cross-platform default — it only needs `gh` and Node.js, so it works under any permission posture and without `jq`:

```bash
node {{NEW_PR_REVIEW_MJS}} --pull-request "<url | owner/repo#num | num>" [--repo "<absolute repo path>"]
```

Platform-specific equivalents (use only if the user prefers the native shell variant):

```powershell
{{NEW_PR_REVIEW_PS1}} -PullRequest "<url | owner/repo#num | num>" [-Repo "<absolute repo path>"]
```

```bash
{{NEW_PR_REVIEW_SH}} --pull-request "<url | owner/repo#num | num>" [--repo "<absolute repo path>"]
```

The bash variant additionally requires `jq`. If neither PowerShell nor `jq` is available, fall back to the Node helper.

Install or refresh the global Codex and Claude skills:

```powershell
{{INSTALL_PS1}}
```

On macOS/Linux:

```bash
{{INSTALL_SH}}
```
