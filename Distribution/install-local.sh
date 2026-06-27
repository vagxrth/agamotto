#!/usr/bin/env bash
#
# Agamotto - build a Release app and install it to /Applications for everyday
# local use. NO Apple Developer Program, NO notarization required.
#
# Why this is fine: notarization / Developer ID only matters for apps that
# travel to OTHER Macs, where Gatekeeper checks the download "quarantine" flag.
# An app you build and copy locally is never quarantined, so it just runs. It is
# signed with your free Apple Development certificate (a stable identity, so the
# Screen Recording / Microphone permissions you grant stick across launches).
#
# Usage:  Distribution/install-local.sh   (re-run anytime to update the copy)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT="${REPO_ROOT}/Agamotto/Agamotto.xcodeproj"
SCHEME="Agamotto"
CONFIG="Release"
DERIVED="${REPO_ROOT}/build/local"
DEST="/Applications/Agamotto.app"

note() { printf '\n\033[1;32m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

note "Building ${SCHEME} (${CONFIG})..."
xcodebuild -project "${PROJECT}" -scheme "${SCHEME}" -configuration "${CONFIG}" \
  -derivedDataPath "${DERIVED}" \
  -destination 'platform=macOS' \
  -allowProvisioningUpdates \
  build

APP="${DERIVED}/Build/Products/${CONFIG}/Agamotto.app"
[ -d "${APP}" ] || fail "Build did not produce ${APP}"

note "Installing to ${DEST}"
# Quit any running copy so we can replace the bundle (graceful, then forced).
osascript -e 'quit app "Agamotto"' 2>/dev/null || true
pkill -x Agamotto 2>/dev/null || true
rm -rf "${DEST}"
cp -R "${APP}" "${DEST}"
xattr -dr com.apple.quarantine "${DEST}" 2>/dev/null || true

note "Launching..."
open "${DEST}"

note "Done - Agamotto is in /Applications and running (look in the menu bar)."
echo "   - First launch: grant Screen Recording (and Microphone) when asked,"
echo "     or in System Settings > Privacy & Security."
echo "   - After re-installing, if recording stops: toggle Agamotto off/on under"
echo "     System Settings > Privacy & Security > Screen Recording."
echo "   - Auto-start at login: System Settings > General > Login Items > +."
