#!/bin/sh
# Builds dist/ and pushes it to the `dist` branch on origin, the branch people add as a
# marketplace. The branch holds only dist/'s contents, one commit per publish, each naming
# the source commit it was built from.
#
#   scripts/publish.sh
#
# Refuses a dirty working tree, so every publish matches a commit on main. The commit is
# made with a scratch index, so this checkout's branch and index are never touched.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

remote="origin"
branch="dist"
index="$root/build/publish.index"

if [ -n "$(git status --porcelain)" ]; then
  echo "working tree has changes: commit them first, so the publish matches a commit" >&2
  exit 1
fi

scripts/dist.sh
version="$(tr -d '[:space:]' < dist/desk-buddy/VERSION)"
source_commit="$(git rev-parse --short HEAD)"

# The branch's tip, if it exists yet. The first publish starts it as an orphan.
parent=""
if git fetch -q "$remote" "+refs/heads/$branch:refs/remotes/$remote/$branch" 2>/dev/null; then
  parent="$(git rev-parse "refs/remotes/$remote/$branch")"
fi

rm -f "$index"
GIT_INDEX_FILE="$index" git --work-tree=dist add -A -f .
tree="$(GIT_INDEX_FILE="$index" git write-tree)"
rm -f "$index"

if [ -n "$parent" ]; then
  if [ "$tree" = "$(git rev-parse "$parent^{tree}")" ]; then
    echo "$branch already has this build ($version); nothing to publish"
    exit 0
  fi
  # Installed plugins only update when the version changes.
  if [ "$version" = "$(git show "$parent:desk-buddy/VERSION" 2>/dev/null | tr -d '[:space:]')" ]; then
    echo "warning: $version is already published; bump src/mod/VERSION so installs update" >&2
  fi
  commit="$(git commit-tree "$tree" -p "$parent" -m "desk-buddy $version from $source_commit")"
else
  commit="$(git commit-tree "$tree" -m "desk-buddy $version from $source_commit")"
fi

git push "$remote" "$commit:refs/heads/$branch"
echo "Published desk-buddy $version to $remote/$branch"
