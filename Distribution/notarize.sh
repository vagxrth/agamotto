#!/usr/bin/env bash
#
# Agamotto — Developer ID release pipeline:
#   archive → export (Developer ID) → notarize → staple → verify.
#
# ──────────────────────────────────────────────────────────────────────────
# ONE-TIME SETUP (needs a paid Apple Developer Program membership):
#
#   1. Create a "Developer ID Application" certificate:
#        Xcode → Settings → Accounts → (your team) → Manage Certificates
#              → + → Developer ID Application
#
#   2. Save a notary credential profile to the keychain (so the script can
#      submit non-interactively):
#        xcrun notarytool store-credentials "agamotto-notary" \
#            --apple-id  "you@example.com" \
#            --team-id   "6W44X8B23Q" \
#            --password  "xxxx-xxxx-xxxx-xxxx"
#      The password is an *app-specific password* from
#      appleid.apple.com → Sign-In & Security → App-Specific Passwords
#      (NOT your normal Apple ID password).
# ──────────────────────────────────────────────────────────────────────────
#
# USAGE:
#   Distribution/notarize.sh
#   NOTARY_PROFILE=other-profile Distribution/notarize.sh   # override profile name
#
# Output: build/Agamotto.app (notarized + stapled) and build/Agamotto.zip.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT="$REPO_ROOT/Agamotto/Agamotto.xcodeproj"
SCHEME="Agamotto"
CONFIG="Release"
APP_NAME="Agamotto"
NOTARY_PROFILE="${NOTARY_PROFILE:-agamotto-notary}"

BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"
ZIP_PATH="$BUILD_DIR/$APP_NAME.zip"
EXPORT_OPTIONS="$SCRIPT_DIR/ExportOptions.plist"

note() { printf '\n\033[1;32m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31m%s\033[0m\n' "❌ $1" >&2; exit 1; }

# ── preflight: fail early with a useful message if the cert isn't installed ──
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  fail "No 'Developer ID Application' certificate found in the keychain.
   Enroll in the Apple Developer Program, then create one in:
   Xcode → Settings → Accounts → (team) → Manage Certificates → + → Developer ID Application"
fi

mkdir -p "$BUILD_DIR"

# ── archive ──
note "Archiving ($CONFIG)…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  clean archive

# ── export with Developer ID signing ──
note "Exporting (Developer ID)…"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates

[ -d "$APP_PATH" ] || fail "Export did not produce $APP_PATH"

# ── verify signature + hardened runtime before submitting ──
note "Verifying signature & hardened runtime…"
codesign --verify --strict --verbose=2 "$APP_PATH"
codesign -dvv "$APP_PATH" 2>&1 | grep -E 'Authority=|flags=|TeamIdentifier=' || true

# ── notarize ──
note "Zipping for notarization…"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

note "Submitting to Apple notary service (this can take a few minutes)…"
SUBMIT_LOG="$(xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
echo "$SUBMIT_LOG"
if ! grep -q "status: Accepted" <<<"$SUBMIT_LOG"; then
  SUB_ID="$(grep -m1 -E '^[[:space:]]*id:' <<<"$SUBMIT_LOG" | awk '{print $2}')"
  if [ -n "${SUB_ID:-}" ]; then
    echo "--- notary log ---"
    xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE" || true
  fi
  fail "Notarization was not accepted (see log above)."
fi

# ── staple + final verification ──
note "Stapling ticket…"
xcrun stapler staple "$APP_PATH"

note "Re-zipping stapled app for distribution…"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

note "Gatekeeper assessment…"
spctl --assess --type execute --verbose=4 "$APP_PATH" || true
xcrun stapler validate "$APP_PATH"

note "Done."
echo "   Notarized + stapled app: $APP_PATH"
echo "   Distributable zip:       $ZIP_PATH"
