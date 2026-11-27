#!/usr/bin/env bash
# Installs Interview Helper from the latest GitHub release:
#
#   curl -fsSL https://raw.githubusercontent.com/livevasiliy/interview-helper/main/scripts/install.sh | bash
#
# A specific version:  ... | VERSION=v0.2.0 bash
# Read it first:       curl -fsSL <url> -o install.sh && less install.sh && bash install.sh
#
# What it does: downloads the DMG and its SHA-256 from the release, verifies the checksum,
# copies InterviewHelper.app to /Applications (replacing an older copy) and opens it.
# Everything is wrapped in a function so a truncated download cannot run half a script.
set -euo pipefail

main() {
  local repo="livevasiliy/interview-helper"
  local version="${VERSION:-latest}"
  local base
  if [ "$version" = "latest" ]; then
    base="https://github.com/$repo/releases/latest/download"
  else
    base="https://github.com/$repo/releases/download/$version"
  fi

  [ "$(uname -s)" = "Darwin" ] || { echo "Interview Helper is a macOS app." >&2; exit 1; }
  local major
  major=$(sw_vers -productVersion | cut -d. -f1)
  [ "$major" -ge 13 ] || { echo "Needs macOS 13 or newer (this is $(sw_vers -productVersion))." >&2; exit 1; }

  # Globals on purpose: the EXIT trap runs after main() has returned, when locals are gone.
  TMP_DIR=$(mktemp -d)
  MOUNT_DIR=""
  cleanup() {
    if [ -n "${MOUNT_DIR:-}" ]; then hdiutil detach -quiet "$MOUNT_DIR" >/dev/null 2>&1 || true; fi
    rm -rf "${TMP_DIR:-}"
  }
  trap cleanup EXIT
  local tmp="$TMP_DIR"

  echo "==> Downloading Interview Helper ($version)"
  curl -fSL --progress-bar "$base/InterviewHelper.dmg" -o "$tmp/InterviewHelper.dmg"
  curl -fsSL "$base/InterviewHelper.dmg.sha256" -o "$tmp/InterviewHelper.dmg.sha256"

  echo "==> Verifying the checksum"
  (cd "$tmp" && shasum -a 256 -c InterviewHelper.dmg.sha256 >/dev/null) \
    || { echo "Checksum mismatch: the download is corrupted or was tampered with. Nothing was installed." >&2; exit 1; }

  echo "==> Installing to /Applications"
  local mount="$tmp/mnt"
  mkdir -p "$mount"
  MOUNT_DIR="$mount"
  hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$tmp/InterviewHelper.dmg" >/dev/null
  [ -d "$mount/InterviewHelper.app" ] || { echo "The disk image has no InterviewHelper.app." >&2; exit 1; }

  pkill -x InterviewHelper 2>/dev/null || true   # an older copy must not keep running (shared hotkeys)
  sleep 1
  local dest="/Applications"
  if [ ! -w "$dest" ]; then dest="$HOME/Applications"; mkdir -p "$dest"; fi
  rm -rf "$dest/InterviewHelper.app"
  ditto "$mount/InterviewHelper.app" "$dest/InterviewHelper.app"
  # curl sets no quarantine flag; clear it anyway in case a proxy or tool added one.
  find "$dest/InterviewHelper.app" -exec xattr -d com.apple.quarantine {} \; >/dev/null 2>&1 || true

  echo "==> Installed: $dest/InterviewHelper.app"
  echo "    The app is not notarized by Apple; it was verified above against the release checksum."
  echo "    On first launch macOS asks for Microphone and Screen Recording access."
  open "$dest/InterviewHelper.app"
}

main "$@"
