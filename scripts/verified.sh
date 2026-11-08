#!/bin/sh
# Runs a verification once per tree.
#
#   scripts/verified.sh NAME [ALSO ...] -- COMMAND [ARGS ...]
#
# The key is the tree of the working directory as it is now: tracked changes
# and untracked files included, ignored files (deps, _build, cover) left out.
# When NAME already passed on this tree, it says so and exits 0 without running
# COMMAND. When COMMAND passes, NAME and every ALSO (verifications COMMAND
# covers, such as the suite inside `make ci`) are marked as passed on the tree
# it started from. A failure marks nothing. FORCE=1 runs COMMAND regardless.
#
# The marks live in the git dir of the checkout or worktree (pm-verified/), so
# each worktree keeps its own and they outlive a restart of the runner.
set -eu

name=$1
shift
also=""
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
  also="$also $1"
  shift
done
[ "$#" -gt 0 ] && shift

tree=""
if git rev-parse --git-dir >/dev/null 2>&1; then
  index=$(mktemp "${TMPDIR:-/tmp}/pm-verified-index.XXXXXX")
  # A copy of the real index keeps git's stat cache: only changed files are hashed.
  cp "$(git rev-parse --git-path index)" "$index" 2>/dev/null || rm -f "$index"
  tree=$(GIT_INDEX_FILE=$index git add -A >/dev/null 2>&1 && GIT_INDEX_FILE=$index git write-tree 2>/dev/null) || tree=""
  rm -f "$index"
fi

if [ -z "$tree" ]; then
  exec "$@"
fi

dir=$(git rev-parse --git-path pm-verified)
mark() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

if [ "${FORCE:-}" != "1" ] && [ -e "$dir/$(mark "$name")-$tree" ]; then
  echo "verified: $name already passed on this tree ($(echo "$tree" | cut -c1-12)); not run again (FORCE=1 runs it)."
  exit 0
fi

"$@"

mkdir -p "$dir"
for n in $name $also; do
  : > "$dir/$(mark "$n")-$tree"
done
# Keep the newest marks only.
ls -t "$dir" | tail -n +201 | while read -r old; do rm -f "$dir/$old"; done
