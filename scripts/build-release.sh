#!/usr/bin/env bash
# Builds an installable Interview Helper: dist/InterviewHelper.app and dist/InterviewHelper-<version>.dmg
#
#   scripts/build-release.sh
#
# Needs: Xcode, XcodeGen, and a Local.xcconfig with DEVELOPMENT_TEAM (see Local.xcconfig.example).
# The app is signed with your "Apple Development" certificate, so it runs on this Mac (and any Mac
# registered to your team). Handing it to other people needs a Developer ID certificate + notarization.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)
DERIVED=.build/xcode-release
APP="$DERIVED/Build/Products/Release/InterviewHelper.app"

echo "==> Generating the Xcode project"
xcodegen generate

echo "==> Building Release ($VERSION)"
xcodebuild -project InterviewHelper.xcodeproj -scheme InterviewHelper-macOS \
  -configuration Release -derivedDataPath "$DERIVED" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build | tail -3

[ -d "$APP" ] || { echo "Build did not produce $APP" >&2; exit 1; }

echo "==> Verifying the signature"
codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier|flags" || true
echo "architectures: $(lipo -archs "$APP/Contents/MacOS/InterviewHelper")"
if codesign -d --entitlements - "$APP" 2>&1 | grep -q "get-task-allow"; then
  echo "WARNING: the debugger entitlement get-task-allow is present in the Release build" >&2
fi

echo "==> Copying to dist/"
mkdir -p dist
rm -rf dist/InterviewHelper.app dist/dmgroot
ditto "$APP" dist/InterviewHelper.app

echo "==> Creating the disk image"
mkdir -p dist/dmgroot
ditto "$APP" dist/dmgroot/InterviewHelper.app
ln -s /Applications dist/dmgroot/Applications
rm -f "dist/InterviewHelper-$VERSION.dmg"
hdiutil create -quiet -volname "Interview Helper" -srcfolder dist/dmgroot -ov -format UDZO "dist/InterviewHelper-$VERSION.dmg"
rm -rf dist/dmgroot

# Release assets have fixed names so ".../releases/latest/download/InterviewHelper.dmg" always works
# (scripts/install.sh relies on it), plus a checksum the installer verifies.
cp "dist/InterviewHelper-$VERSION.dmg" dist/InterviewHelper.dmg
(cd dist && shasum -a 256 InterviewHelper.dmg > InterviewHelper.dmg.sha256)

echo
echo "Done:"
du -sh dist/InterviewHelper.app "dist/InterviewHelper-$VERSION.dmg"
echo "Release assets: dist/InterviewHelper.dmg, dist/InterviewHelper.dmg.sha256"
