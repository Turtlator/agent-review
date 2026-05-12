#!/usr/bin/env bash
set -euo pipefail

pr_ref=""
initiator="claude"
workspace=""
repo=""
unsafe="false"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --pull-request <url|owner/repo#num|num> [--initiator claude|codex] [--workspace <path>] [--repo <local repo>] [--unsafe]

Orchestrates a collaborative PR review between Claude Code and Codex.

Flow:
  1. Initiator reviews independently              (parallel with 2)
  2. Requested reviews independently              (parallel with 1)
  3. Requested cross-checks initiator's findings  (after 1 and 2)
  4. Initiator synthesizes                        (after 3)

Requires:
  - 'claude' CLI in PATH
  - 'codex' CLI in PATH
  - 'gh' and 'jq' (used by new-pr-review.sh)

Flags:
  --initiator    Which agent initiates (default: claude)
  --workspace    Override \$AGENT_REVIEW_WORKSPACE
  --repo         Local repo path (only needed when --pull-request is just a number)
  --unsafe       Pass --dangerously-skip-permissions to each CLI for unattended runs.
                 Off by default - the agents respect your normal permission settings.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pull-request|--pr) pr_ref="${2:-}"; shift 2 ;;
    --initiator) initiator="${2:-}"; shift 2 ;;
    --workspace) workspace="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    --unsafe) unsafe="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$pr_ref" ]]; then
  echo "--pull-request is required" >&2
  usage >&2
  exit 2
fi

case "$initiator" in
  claude|codex) ;;
  *) echo "--initiator must be 'claude' or 'codex'" >&2; exit 2 ;;
esac

if [[ "$initiator" == "claude" ]]; then
  requested="codex"
else
  requested="claude"
fi

for cli in claude codex; do
  if ! command -v "$cli" >/dev/null 2>&1; then
    echo "'$cli' not found in PATH. Install it before using this orchestrator." >&2
    exit 1
  fi
done

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
skills_root="$(cd -- "$script_dir/.." && pwd -P)"
tool_root="$(cd -- "$skills_root/.." && pwd -P)"

new_pr_args=("--pull-request" "$pr_ref")
[[ -n "$workspace" ]] && new_pr_args+=("--workspace" "$workspace")
[[ -n "$repo" ]] && new_pr_args+=("--repo" "$repo")

review_folder="$("$script_dir/new-pr-review.sh" "${new_pr_args[@]}")"
if [[ ! -d "$review_folder" ]]; then
  echo "Failed to create review folder. Got: '$review_folder'" >&2
  exit 1
fi

mkdir -p "$review_folder/.collab"

echo "Review folder: $review_folder"
echo "Initiator:     $initiator"
echo "Requested:     $requested"

invoke_claude() {
  local prompt="$1"
  local log="$2"
  local extra=()
  if [[ "$unsafe" == "true" ]]; then
    extra+=("--dangerously-skip-permissions")
  fi
  (cd "$review_folder" && claude -p "${extra[@]}" --add-dir "$tool_root" "$prompt") > "$log" 2>&1
}

invoke_codex() {
  local prompt="$1"
  local log="$2"
  local extra=()
  if [[ "$unsafe" == "true" ]]; then
    extra+=("--dangerously-bypass-approvals-and-sandbox")
  else
    extra+=("--sandbox" "workspace-write")
  fi
  codex exec "${extra[@]}" --skip-git-repo-check -C "$review_folder" "$prompt" > "$log" 2>&1
}

invoke_agent() {
  local agent="$1"
  local prompt="$2"
  local log="$3"
  if [[ "$agent" == "claude" ]]; then
    invoke_claude "$prompt" "$log"
  else
    invoke_codex "$prompt" "$log"
  fi
}

initiator_file="${initiator}.md"
requested_file="${requested}.md"
log_dir="$review_folder/.collab"

phase1_initiator_prompt="Use the agent-review skill. Read request.md and pr.diff in the current directory. Write your independent review to $initiator_file in the current directory. Do not read $requested_file."
phase1_requested_prompt="Use the agent-review skill. Read request.md and pr.diff in the current directory. Write your independent review to $requested_file in the current directory. Do not read $initiator_file."

echo ""
echo "Phase 1: both agents reviewing independently (parallel)..."
invoke_agent "$initiator" "$phase1_initiator_prompt" "$log_dir/phase1-$initiator.log" &
pid1=$!
invoke_agent "$requested" "$phase1_requested_prompt" "$log_dir/phase1-$requested.log" &
pid2=$!

set +e
wait "$pid1"; rc1=$?
wait "$pid2"; rc2=$?
set -e

if [[ $rc1 -ne 0 ]]; then
  echo "Phase 1 ($initiator) failed (exit $rc1). See $log_dir/phase1-$initiator.log" >&2
  exit 1
fi
if [[ $rc2 -ne 0 ]]; then
  echo "Phase 1 ($requested) failed (exit $rc2). See $log_dir/phase1-$requested.log" >&2
  exit 1
fi

phase2_prompt="Use the agent-review skill. Read $initiator_file in the current directory. Append a '## Cross-check (vs ${initiator})' section to $requested_file per the protocol with four subsections: 'Agreed', 'Disagreed', 'They caught, I missed', 'I still stand by'. Only edit $requested_file."

echo "Phase 2: $requested cross-checking $initiator's findings..."
if ! invoke_agent "$requested" "$phase2_prompt" "$log_dir/phase2-$requested.log"; then
  echo "Phase 2 failed. See $log_dir/phase2-$requested.log" >&2
  exit 1
fi

phase3_prompt="Use the agent-review skill. Read $initiator_file (your own independent review) and $requested_file (their independent review plus their '## Cross-check' section about your review). Write the consolidated synthesis to synthesis.md per the protocol: Confirmed (both flagged), Disputed (one flagged, the other disagreed), Single-source (only one flagged)."

echo "Phase 3: $initiator synthesizing..."
if ! invoke_agent "$initiator" "$phase3_prompt" "$log_dir/phase3-$initiator.log"; then
  echo "Phase 3 failed. See $log_dir/phase3-$initiator.log" >&2
  exit 1
fi

echo ""
echo "Done. Review at: $review_folder"
echo "Files in folder:"
ls -1 "$review_folder"
