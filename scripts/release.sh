#!/usr/bin/env bash
# Publishes a release from this Mac (there is no CI):
#
#   scripts/release.sh 0.5.0            # checks, tests, build; stops before publishing
#   scripts/release.sh 0.5.0 --publish  # ... and commits the version bump, pushes, creates the GitHub release
#   scripts/release.sh --notes 0.4.0    # prints that version's section of CHANGELOG.md
#
# Before running: add a "## [<version>] — YYYY-MM-DD" section to CHANGELOG.md and commit it.
# Needs: Xcode, XcodeGen, Local.xcconfig, and for --publish a logged-in `gh`.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="livevasiliy/interview-helper"

notes_for() {
  # The body of "## [$1] ..." up to the next "## [" heading.
  awk -v v="$1" '
    $0 ~ "^## \\[" v "\\]" { found = 1; next }
    found && /^## \[/ { exit }
    found && /^\[[0-9]/ { exit }
    found { print }
  ' CHANGELOG.md | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

if [ "${1:-}" = "--notes" ]; then
  notes_for "${2:?usage: release.sh --notes <version>}"
  exit 0
fi

VERSION="${1:?usage: release.sh <version> [--publish]}"
PUBLISH="${2:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must look like 1.2.3" >&2; exit 1; }
TAG="v$VERSION"

CURRENT=$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)
newer() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ] && [ "$1" != "$2" ]; }
newer "$VERSION" "$CURRENT" || { echo "$VERSION is not newer than the current $CURRENT" >&2; exit 1; }

[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "Release from the main branch." >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "The working tree has uncommitted changes. Commit or stash them first." >&2; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "Tag $TAG already exists." >&2; exit 1; }

NOTES=$(notes_for "$VERSION")
[ -n "$NOTES" ] || { echo "CHANGELOG.md has no (or an empty) section for [$VERSION]. Write it and commit first." >&2; exit 1; }

if [ "$PUBLISH" = "--publish" ]; then
  gh auth status >/dev/null 2>&1 || { echo "gh is not logged in: run gh auth login" >&2; exit 1; }
fi

echo "==> Unit tests"
TEST_LOG=$(swift test 2>&1 || true)
echo "$TEST_LOG" | grep -E "error:|Executed .* tests" | tail -2
echo "$TEST_LOG" | grep "Executed .* tests" | tail -1 | grep -q "with 0 failures" || { echo "Unit tests failed." >&2; exit 1; }

echo "==> Bumping MARKETING_VERSION $CURRENT -> $VERSION"
sed -i '' "s/MARKETING_VERSION: \"$CURRENT\"/MARKETING_VERSION: \"$VERSION\"/" project.yml

echo "==> Building the release"
scripts/build-release.sh | tail -4
BUILT=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" dist/InterviewHelper.app/Contents/Info.plist)
[ "$BUILT" = "$VERSION" ] || { echo "The built app says $BUILT, not $VERSION." >&2; git checkout project.yml; exit 1; }
(cd dist && shasum -a 256 -c InterviewHelper.dmg.sha256)

if [ "$PUBLISH" != "--publish" ]; then
  git checkout project.yml
  echo
  echo "Dry run finished: dist/InterviewHelper.dmg is $VERSION and the checksum matches."
  echo "Release notes that would be published:"; echo "$NOTES"
  echo "Publish with: scripts/release.sh $VERSION --publish"
  exit 0
fi

echo "==> Committing, pushing and publishing $TAG"
git add project.yml
git commit -q -m "Bump version to $VERSION"
git push
gh release create "$TAG" dist/InterviewHelper.dmg dist/InterviewHelper.dmg.sha256 \
  --repo "$REPO" --target main --title "Interview Helper $VERSION" --notes "$NOTES"
echo "Published: https://github.com/$REPO/releases/tag/$TAG"
