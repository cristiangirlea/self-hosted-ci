#!/usr/bin/env bash
# Fails if any tracked file, or any commit message, contains a word from the list: one word or name
# per line, matched case-insensitively as a whole word (so "name" does not match "namespace");
# blank lines and lines starting with # are skipped. Run it before every push of a public copy, with
# a list kept somewhere private:
#   scripts/scrub-check.sh ../private-repo/.scrub-words
#
# Only a clean "no match" passes. Any other outcome of a search (a crash, an unreadable file) fails
# the check: a check that passes when it cannot run is worse than none.
set -uo pipefail
list=${1:?usage: scrub-check.sh <word list>}
test -r "$list" || { echo "scrub-check: cannot read $list" >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$list" > "$tmp/patterns" || true
test -s "$tmp/patterns" || { echo "scrub-check: $list holds no words" >&2; exit 2; }

# search <description> <directory> <git grep arguments...>: 0 = found, 1 = clean, else = error.
search() {
  local what=$1 dir=$2; shift 2
  git -C "$dir" grep -n -i -w -F -f "$tmp/patterns" "$@"
  case $? in
    0) echo "scrub-check: $what above contain a listed word" >&2; return 0 ;;
    1) return 1 ;;
    *) echo "scrub-check: searching $what failed; treating it as a failure" >&2; exit 2 ;;
  esac
}

found=0
search "tracked files" . -- . && found=1
if git rev-parse -q --verify HEAD >/dev/null; then
  git log --format='%H %s%n%b' > "$tmp/messages" || { echo "scrub-check: git log failed" >&2; exit 2; }
  # Outside the repository, so git grep searches the file without an index.
  search "commit messages" "$tmp" --no-index -- messages && found=1
fi
test $found -eq 0 || exit 1
echo "scrub-check: no listed word in $(git ls-files | wc -l | tr -d ' ') tracked files or $(git rev-list --count HEAD 2>/dev/null || echo 0) commit messages"
