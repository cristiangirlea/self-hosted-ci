#!/usr/bin/env bash
# Fetches the actions the repositories' workflows use into a folder the runner image copies in:
#   scripts/action-cache.sh <owner> <folder> <repository>...
#
# The runner reads <folder>/<owner>_<repo>/<sha>.tar.gz before it downloads an action
# (ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE, src/Runner.Worker/ActionManager.cs in actions/runner), so a
# job no longer asks codeload.github.com for it. Runners behind one address that start together
# otherwise share codeload's anonymous limit and fail with "429 (Too Many Requests)". An action
# missing here, or a workflow that moved to a newer one, is downloaded as before.
#
# It reads each repository's workflows on its default branch and fetches with gh, so the calls are
# authenticated and made once per image build, not once per job. Local actions (./), docker://
# actions and reusable workflows are left out: the runner does not download those as archives.
set -euo pipefail
owner=${1:?usage: action-cache.sh <owner> <folder> <repository>...}
dest=${2:?usage: action-cache.sh <owner> <folder> <repository>...}
shift 2
test $# -gt 0 || { echo "action-cache: no repositories given" >&2; exit 2; }
command -v gh >/dev/null || { echo "action-cache: gh is required (and gh auth login)" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Every uses: line in every workflow of every repository. A repository without workflows (404) is
# skipped; any other failure (a rate limit, lost access) stops here, before the old folder is
# cleared, rather than build an image that silently lacks a repository's actions.
for repo in "$@"; do
  if ! gh api "repos/$owner/$repo/contents/.github/workflows" \
    -q '.[] | select(.type == "file") | select(.name | test("\\.ya?ml$")) | .path' > "$tmp/paths" 2> "$tmp/err"; then
    grep -q "HTTP 404" "$tmp/err" || { echo "action-cache: cannot list $repo's workflows:" >&2; cat "$tmp/err" >&2; exit 1; }
    echo "action-cache: $repo has no .github/workflows, skipped" >&2
    continue
  fi
  while read -r path; do
    gh api -H "Accept: application/vnd.github.raw" "repos/$owner/$repo/contents/$path" >> "$tmp/workflows"
    echo >> "$tmp/workflows"
  done < "$tmp/paths"
done
test -s "$tmp/workflows" || { echo "action-cache: no workflows found" >&2; exit 1; }

grep -oE '^[[:space:]-]*uses:[[:space:]]*[^[:space:]#]+' "$tmp/workflows" \
  | sed -E 's/^[[:space:]-]*uses:[[:space:]]*//; s/^["'\'']//; s/["'\'']$//' \
  | grep -vE '^(\./|docker://)' | grep -v '/\.github/workflows/' | grep '@' | sort -u > "$tmp/refs" || true

# Start from an empty folder, so an action no workflow uses any more leaves the image.
mkdir -p "$dest"
find "$dest" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +

fetched=0 failed=0
while read -r ref; do
  action=${ref%@*} version=${ref##*@}
  full=$(cut -d/ -f1-2 <<< "$action")
  if [[ $version =~ ^[0-9a-f]{40}$ ]]; then
    sha=$version
  elif ! sha=$(gh api "repos/$full/commits/$version" -q .sha 2>/dev/null) || [ -z "$sha" ]; then
    echo "action-cache: cannot resolve $ref, left to download at run time" >&2
    failed=$((failed + 1)); continue
  fi
  dir="$dest/${full/\//_}"
  file="$dir/$sha.tar.gz"
  test -s "$file" && continue
  mkdir -p "$dir"
  # A repository archive holds exactly one folder; anything else is not what the runner expects.
  if gh api "repos/$full/tarball/$sha" > "$file.part" 2>/dev/null \
     && tar -tzf "$file.part" > "$tmp/list" 2>/dev/null \
     && test "$(cut -d/ -f1 "$tmp/list" | sort -u | wc -l)" -eq 1; then
    mv "$file.part" "$file"
    echo "$full@$sha ($ref)"
    fetched=$((fetched + 1))
  else
    rm -f "$file.part"
    echo "action-cache: cannot fetch $ref, left to download at run time" >&2
    failed=$((failed + 1))
  fi
done < "$tmp/refs"

echo "action-cache: $fetched archives in $dest ($(du -sh "$dest" | cut -f1)), $failed left to download"
