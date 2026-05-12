#!/usr/bin/env bash
set -euo pipefail

slug=""
repo=""
workspace=""
force="false"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --slug <slug> [--repo <repo path>] [--workspace <workspace path>] [--force]

Creates a new review folder under <workspace>/reviews/<date>-<slug> with templates copied in.

Workspace resolution: --workspace flag > \$AGENT_REVIEW_WORKSPACE env var > \$HOME/.agent-review
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug) slug="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    --workspace) workspace="${2:-}"; shift 2 ;;
    --force) force="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$slug" ]]; then
  echo "--slug is required" >&2
  usage >&2
  exit 2
fi

if [[ ! "$slug" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
  echo "Invalid slug '$slug'. Use letters, digits, hyphens; must start with letter or digit." >&2
  exit 2
fi

if [[ -z "$repo" ]]; then
  repo="$(pwd)"
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

date_str="$(date +%Y-%m-%d)"
slug_lower="$(echo "$slug" | tr '[:upper:]' '[:lower:]')"
folder_name="$date_str-$slug_lower"
reviews_dir="$workspace/reviews"
review_folder="$reviews_dir/$folder_name"
template_root="$tool_root/templates"

mkdir -p "$reviews_dir"

if [[ -d "$review_folder" && "$force" != "true" ]]; then
  echo "Review folder already exists: $review_folder. Use --force to reuse it." >&2
  exit 1
fi

mkdir -p "$review_folder"

copy_template() {
  local src_name="$1"
  local dest_name="$2"
  local src="$template_root/$src_name"
  local dest="$review_folder/$dest_name"
  if [[ ! -f "$src" ]]; then
    echo "Missing template: $src" >&2
    exit 1
  fi
  if [[ ! -f "$dest" || "$force" == "true" ]]; then
    cp "$src" "$dest"
  fi
}

copy_template "review-request.md" "request.md"
copy_template "resolution.md" "resolution.md"

request_path="$review_folder/request.md"
content="$(cat "$request_path")"
content="${content//Repo: <absolute path to repo>/Repo: $repo}"
content="${content//Created: <YYYY-MM-DD>/Created: $date_str}"
printf '%s\n' "$content" > "$request_path"

echo "$review_folder"
