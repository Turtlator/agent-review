#!/usr/bin/env bash
set -euo pipefail

pr_ref=""
repo=""
workspace=""
slug=""
force="false"
no_diff="false"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --pull-request <url|owner/repo#num|num> [--repo <repo path>] [--workspace <workspace path>] [--slug <slug>] [--force] [--no-diff]

Creates a review folder pre-filled from a GitHub pull request. Requires 'gh' and 'jq'.

Workspace resolution: --workspace flag > \$AGENT_REVIEW_WORKSPACE env var > \$HOME/.agent-review
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pull-request|--pr) pr_ref="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    --workspace) workspace="${2:-}"; shift 2 ;;
    --slug) slug="${2:-}"; shift 2 ;;
    --force) force="true"; shift ;;
    --no-diff) no_diff="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$pr_ref" ]]; then
  echo "--pull-request is required" >&2
  usage >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI 'gh' not found in PATH. Install from https://cli.github.com/ and run 'gh auth login'." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "'jq' not found in PATH. Install via 'brew install jq' (macOS) or your package manager." >&2
  exit 1
fi

if [[ -n "$repo" ]]; then
  if [[ ! -d "$repo" ]]; then
    echo "Repo path does not exist: $repo" >&2
    exit 1
  fi
  repo="$(cd "$repo" && pwd -P)"
fi

if [[ -z "$workspace" ]]; then
  if [[ -n "${AGENT_REVIEW_WORKSPACE:-}" ]]; then
    workspace="$AGENT_REVIEW_WORKSPACE"
  else
    workspace="$HOME/.agent-review"
  fi
fi

mkdir -p "$workspace"
workspace="$(cd "$workspace" && pwd -P)"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
skills_root="$(cd -- "$script_dir/.." && pwd -P)"
tool_root="$(cd -- "$skills_root/.." && pwd -P)"

run_gh() {
  if [[ -n "$repo" ]]; then
    (cd "$repo" && gh "$@")
  else
    gh "$@"
  fi
}

fields='number,title,body,headRefName,baseRefName,url,author,state,isDraft,files,additions,deletions,headRepositoryOwner,headRepository'
if ! pr_json="$(run_gh pr view "$pr_ref" --json "$fields")"; then
  echo "Failed to fetch PR via 'gh pr view $pr_ref'. Confirm the reference is valid and you are authenticated ('gh auth status')." >&2
  exit 1
fi

jq_field() {
  echo "$pr_json" | jq -r "$1"
}

number="$(jq_field '.number')"
title="$(jq_field '.title')"
body="$(jq_field '.body // ""')"
head_ref="$(jq_field '.headRefName')"
base_ref="$(jq_field '.baseRefName')"
url="$(jq_field '.url')"
author="$(jq_field '.author.login // "(unknown)"')"
state="$(jq_field '.state')"
is_draft="$(jq_field '.isDraft')"
additions="$(jq_field '.additions')"
deletions="$(jq_field '.deletions')"
file_count="$(jq_field '.files | length')"

base_full=""
if [[ "$url" =~ github\.com/([^/]+)/([^/]+)/pull/ ]]; then
  base_full="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
else
  base_full="(unknown)"
fi

head_full="$(jq_field '
  if .headRepositoryOwner and .headRepositoryOwner.login and .headRepository and .headRepository.name
  then "\(.headRepositoryOwner.login)/\(.headRepository.name)"
  else "" end
')"

file_list="$(jq_field '.files[]? | "- \(.path) (+\(.additions) / -\(.deletions))"')"
if [[ -z "$file_list" ]]; then
  file_list="- (no files reported by gh pr view)"
fi

if [[ -z "$slug" ]]; then
  title_slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  if (( ${#title_slug} > 40 )); then
    title_slug="${title_slug:0:40}"
    title_slug="${title_slug%-}"
  fi
  if [[ -z "$title_slug" ]]; then
    slug="pr-$number"
  else
    slug="pr-$number-$title_slug"
  fi
fi

if [[ ! "$slug" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
  echo "Computed slug is invalid: '$slug'. Pass --slug to override." >&2
  exit 1
fi

date_str="$(date +%Y-%m-%d)"
folder_name="$date_str-$slug"
reviews_dir="$workspace/reviews"
review_folder="$reviews_dir/$folder_name"
template_root="$tool_root/templates"

mkdir -p "$reviews_dir"

if [[ -d "$review_folder" && "$force" != "true" ]]; then
  echo "Review folder already exists: $review_folder. Use --force to reuse it." >&2
  exit 1
fi

mkdir -p "$review_folder"

for name in resolution.md synthesis.md; do
  src="$template_root/$name"
  dst="$review_folder/$name"
  if [[ ! -f "$src" ]]; then
    echo "Missing template: $src" >&2
    exit 1
  fi
  if [[ ! -f "$dst" || "$force" == "true" ]]; then
    cp "$src" "$dst"
  fi
done

state_line="$state"
if [[ "$is_draft" == "true" ]]; then
  state_line="$state (draft)"
fi

fork_note=""
if [[ -n "$head_full" && "$head_full" != "$base_full" ]]; then
  fork_note=$'\nHead repo (fork): '"$head_full"
fi

repo_for_request="${repo:-$base_full}"

if [[ -z "$body" ]]; then
  goal="Review GitHub PR #$number: $title. (PR body was empty.)"
else
  goal="Review GitHub PR #$number: $title."$'\n\n'"$body"
fi

diff_note=""
diff_path="$review_folder/pr.diff"
if [[ "$no_diff" != "true" ]]; then
  if diff_text="$(run_gh pr diff "$pr_ref")"; then
    printf '%s\n' "$diff_text" > "$diff_path"
    diff_note=$'\nPR diff snapshot saved to `pr.diff` in this folder (captured at review creation time; re-run `gh pr diff '"$url"$'` for the latest).'
  else
    echo "Warning: failed to capture PR diff via 'gh pr diff $pr_ref'. Continuing without pr.diff." >&2
  fi
fi

request_path="$review_folder/request.md"
cat > "$request_path" <<EOF
# Review: PR #$number - $title

Status: inbox
Repo: $repo_for_request
Branch: $head_ref
PR: $url
Authoring agent: Human
Reviewing agent: Any
Created: $date_str

## Goal

$goal

## Scope

GitHub PR: $url
Base branch: $base_ref
Head branch: $head_ref$fork_note

Changed files (+$additions / -$deletions across $file_count file(s)):

$file_list

## Context

- GitHub repo: $base_full
- Author: $author
- State: $state_line
- Inspect the PR diff at \`pr.diff\` for the review snapshot, or run \`gh pr diff $url\` for the latest.
- If the reviewing agent needs a local checkout, \`gh pr checkout $number\` inside the target repo will fetch the branch.

## Questions

1. <Specific thing to check>
2. <Specific thing to challenge>

## Verification

List commands already run and their outcomes.

\`\`\`text
<command output summary>
\`\`\`

## Notes

This review folder was created from a GitHub PR by the agent-review PR helper.$diff_note
EOF

echo "$review_folder"
