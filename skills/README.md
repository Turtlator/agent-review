# Agent Review Skills Source

This folder contains the shared protocol and source files for installing the `agent-review` skill into Codex and Claude Code.

## Layout

```text
agent-review/skills/
  Install-GlobalSkills.ps1
  install-global-skills.sh
  common/agent-review-protocol.md
  codex/agent-review/SKILL.md
  claude/agent-review/SKILL.md
  claude/collab-review/SKILL.md
  scripts/
    New-AgentReview.ps1
    new-agent-review.sh
    New-PrReview.ps1
    new-pr-review.sh
    new-pr-review.mjs       # cross-platform PR helper (gh + Node, no jq)
    post-pr-review.mjs      # optional: post synthesis back to the PR
    Collab-Review.ps1
    collab-review.sh
```

The Codex and Claude skills are intentionally thin. They both point to `common/agent-review-protocol.md`, so protocol changes can be made once and picked up by both agents.

## Install

The installer creates the workspace at `$HOME/.agent-review` by default (override with `--workspace`/`-Workspace` or `AGENT_REVIEW_WORKSPACE`) and renders each agent's `SKILL.md` with absolute paths to the workspace, protocol, and helper scripts.

Windows PowerShell or PowerShell Core:

```powershell
<tool-root>\skills\Install-GlobalSkills.ps1
```

Bash on macOS/Linux:

```bash
<tool-root>/skills/install-global-skills.sh
```

Destinations:

- Codex: `$HOME/.codex/skills/agent-review/SKILL.md`
- Claude Code: `$HOME/.claude/skills/agent-review/SKILL.md`

Restart any running agent session if it does not discover the new skill.
