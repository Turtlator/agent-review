#!/usr/bin/env bash
set -euo pipefail

agent="Both"
what_if="false"
workspace=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)
      agent="${2:-}"
      shift 2
      ;;
    --workspace)
      workspace="${2:-}"
      shift 2
      ;;
    --what-if|--dry-run)
      what_if="true"
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

case "$agent" in
  Both|Codex|Claude) ;;
  *)
    echo "--agent must be Both, Codex, or Claude" >&2
    exit 2
    ;;
esac

if [[ -z "$workspace" ]]; then
  if [[ -n "${AGENT_REVIEW_WORKSPACE:-}" ]]; then
    workspace="$AGENT_REVIEW_WORKSPACE"
  else
    workspace="$HOME/.agent-review"
  fi
fi

to_portable_path() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$p"
  else
    printf '%s' "$p"
  fi
}

if [[ "$what_if" != "true" ]]; then
  mkdir -p "$workspace"
  workspace="$(cd "$workspace" && pwd -P)"
  mkdir -p "$workspace/reviews" "$workspace/archive"
else
  echo "Would ensure workspace at $workspace (with reviews/ and archive/)"
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tool_root="$(cd -- "$script_dir/.." && pwd -P)"

workspace="$(to_portable_path "$workspace")"
tool_root="$(to_portable_path "$tool_root")"
script_dir_p="$(to_portable_path "$script_dir")"

codex_source_root="$script_dir/codex"
claude_source_root="$script_dir/claude"
codex_dest_root="$HOME/.codex/skills"
claude_dest_root="$HOME/.claude/skills"
protocol_path="$script_dir_p/common/agent-review-protocol.md"
new_review_ps1="$script_dir_p/scripts/New-AgentReview.ps1"
new_review_sh="$script_dir_p/scripts/new-agent-review.sh"
new_pr_review_ps1="$script_dir_p/scripts/New-PrReview.ps1"
new_pr_review_sh="$script_dir_p/scripts/new-pr-review.sh"
new_pr_review_mjs="$script_dir_p/scripts/new-pr-review.mjs"
post_pr_review_mjs="$script_dir_p/scripts/post-pr-review.mjs"
install_ps1="$script_dir_p/Install-GlobalSkills.ps1"
install_sh="$script_dir_p/install-global-skills.sh"

render_template() {
  local source_file="$1"
  sed \
    -e "s|{{AGENT_REVIEW_WORKSPACE}}|$workspace|g" \
    -e "s|{{AGENT_REVIEW_TOOL_ROOT}}|$tool_root|g" \
    -e "s|{{PROTOCOL_PATH}}|$protocol_path|g" \
    -e "s|{{NEW_REVIEW_PS1}}|$new_review_ps1|g" \
    -e "s|{{NEW_REVIEW_SH}}|$new_review_sh|g" \
    -e "s|{{NEW_PR_REVIEW_PS1}}|$new_pr_review_ps1|g" \
    -e "s|{{NEW_PR_REVIEW_SH}}|$new_pr_review_sh|g" \
    -e "s|{{NEW_PR_REVIEW_MJS}}|$new_pr_review_mjs|g" \
    -e "s|{{POST_PR_REVIEW_MJS}}|$post_pr_review_mjs|g" \
    -e "s|{{INSTALL_PS1}}|$install_ps1|g" \
    -e "s|{{INSTALL_SH}}|$install_sh|g" \
    "$source_file"
}

install_skill() {
  local source_dir="$1"
  local dest_dir="$2"
  local name="$3"
  local source_skill="$source_dir/SKILL.md"

  if [[ ! -f "$source_skill" ]]; then
    echo "Missing source SKILL.md for $name at $source_dir" >&2
    exit 1
  fi

  if [[ "$what_if" == "true" ]]; then
    echo "Would install $name skill to $dest_dir"
    return
  fi

  mkdir -p "$dest_dir"
  render_template "$source_skill" > "$dest_dir/SKILL.md"
  echo "Installed $name skill to $dest_dir"
}

install_skills_from_root() {
  local source_root="$1"
  local dest_root="$2"
  local agent_label="$3"
  [[ -d "$source_root" ]] || return 0
  for skill_dir in "$source_root"/*/; do
    [[ -d "$skill_dir" ]] || continue
    local skill_name
    skill_name="$(basename "$skill_dir")"
    install_skill "$skill_dir" "$dest_root/$skill_name" "$agent_label/$skill_name"
  done
}

if [[ "$agent" == "Both" || "$agent" == "Codex" ]]; then
  install_skills_from_root "$codex_source_root" "$codex_dest_root" "Codex"
fi

if [[ "$agent" == "Both" || "$agent" == "Claude" ]]; then
  install_skills_from_root "$claude_source_root" "$claude_dest_root" "Claude"
fi

if [[ "$what_if" != "true" ]]; then
  for sh_script in "$new_review_sh" "$new_pr_review_sh" "$install_sh"; do
    if [[ -f "$sh_script" && ! -x "$sh_script" ]]; then
      chmod +x "$sh_script" || true
    fi
  done
  for mjs_script in "$script_dir/scripts/new-pr-review.mjs" "$script_dir/scripts/post-pr-review.mjs"; do
    if [[ -f "$mjs_script" && ! -x "$mjs_script" ]]; then
      chmod +x "$mjs_script" || true
    fi
  done
fi

echo
echo "Workspace: $workspace"
echo "Shared protocol source:"
echo "  $protocol_path"
echo
echo "Restart Codex or Claude Code if a running session does not discover the refreshed skill."
