# Synthesis

Status: draft
Synthesizer: <Codex | Claude | Human>
Updated: <YYYY-MM-DD HH:mm>

Use this file to reconcile findings after both agents have completed independent review and cross-check. The synthesizer reads `claude.md` and `codex.md` (including their `## Cross-check` sections) and produces a consolidated view here. Final decisions still belong in `resolution.md`.

## Confirmed Findings

Both reviewers flagged this. Highest signal - likely real, worth fixing.

### <Severity>: <finding title>

- File: <absolute path>
- Line: <line number or unknown>
- Claude evidence: <quote or summary from claude.md>
- Codex evidence: <quote or summary from codex.md>
- Recommendation: <agreed fix>

## Disputed Findings

One reviewer flagged it, the other rejected it or framed it differently. Worth a human call.

### <Severity>: <finding title>

- File: <path>
- Claude's position: <summary + reasoning>
- Codex's position: <summary + reasoning>
- Synthesizer's read: <which side seems stronger and why, or "needs human">

## Single-Source Findings

Only one reviewer raised these. Lower signal, but worth a sanity check before discarding.

### From Claude

- <finding title> - <one-line summary; defer to claude.md for full evidence>

### From Codex

- <finding title> - <one-line summary; defer to codex.md for full evidence>

## Notes

Anything else worth surfacing for the human reviewer.
