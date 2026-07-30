#!/bin/bash
# Build a distributable .dmg for MacTemp.
#
#   ./packaging/build_dmg.sh          (run from anywhere; it cd's to the repo root)
#
# Signing behaviour is automatic:
#   * If a "Developer ID Application" certificate is in your keychain, the app
#     is signed with it + the hardened runtime  ->  eligible for notarization.
#   * Otherwise it falls back to an ad-hoc signature (runs on Apple Silicon, but
#     users need the one-time right-click -> Open).
#
# Notarization (optional, needs the Developer ID signature above) runs when you
# provide notarytool credentials, either:
#   NOTARY_PROFILE=<name>                       # from `notarytool store-credentials`
# or:
#   NOTARY_APPLE_ID=... NOTARY_TEAM_ID=... NOTARY_PASSWORD=<app-specific-pw>
#
# Override the signing identity explicitly with:  SIGN_IDENTITY="Developer ID Application: ..."
set -euo pipefail
# Run from the repo root (this script lives in packaging/). All paths below are
# relative to the repo root so dist/ lands there, as the CI workflow expects.
cd "$(dirname "$0")/.."

# The Command Line Tools SDK can be too old to build this; prefer full Xcode.
if [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

APP_NAME="MacTemp"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' packaging/Info.plist)"
DMG_PATH="dist/${APP_NAME}-${VERSION}.dmg"
APP="dist/${APP_NAME}.app"

echo "==> Cleaning previous build"
rm -rf dist
mkdir -p "$APP/Contents/MacOS"

echo "==> Building ${APP_NAME}.app — version ${VERSION}"
cp packaging/Info.plist "$APP/Contents/Info.plist"
xcrun swiftc -swift-version 5 -O \
    -target arm64-apple-macos12.0 \
    -framework Cocoa \
    src/*.swift -o "$APP/Contents/MacOS/${APP_NAME}"

# ----------------------------------------------------------------------------
# Sign (a single Mach-O binary — no nested code, so one bundle signature does it)
# ----------------------------------------------------------------------------
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    # Auto-detect a Developer ID Application identity.
    IDENTITY="$(security find-identity -v -p codesigning \
        | grep -o '"Developer ID Application:.*"' | head -1 | tr -d '"' || true)"
fi

if [[ -n "$IDENTITY" ]]; then
    echo "==> Signing with Developer ID + hardened runtime:"
    echo "    $IDENTITY"
    codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP"
    NOTARIZABLE=1
else
    echo "==> No Developer ID cert found — ad-hoc signing (not notarizable)"
    codesign --force --sign - "$APP"
    NOTARIZABLE=0
fi
codesign --verify --deep --strict "$APP" && echo "    signature OK"

# ----------------------------------------------------------------------------
# Resolve notary credentials (if any)
# ----------------------------------------------------------------------------
NOTARY_ARGS=()
HAVE_NOTARY=0
if [[ "$NOTARIZABLE" == "1" ]]; then
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE"); HAVE_NOTARY=1
    elif [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
        NOTARY_ARGS=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
        HAVE_NOTARY=1
    fi
    if [[ "$HAVE_NOTARY" == "1" ]] && ! xcrun --find notarytool >/dev/null 2>&1; then
        echo "==> WARNING: notarytool not found (install full Xcode). Skipping notarization."
        HAVE_NOTARY=0
    fi
fi

# ----------------------------------------------------------------------------
# Notarize + staple the APP itself (so the ticket travels with it — works even
# on a first launch while offline). notarytool takes a zip, not a bare .app.
# ----------------------------------------------------------------------------
if [[ "$HAVE_NOTARY" == "1" ]]; then
    echo "==> Notarizing the app (this can take a few minutes)…"
    ZIP="dist/${APP_NAME}.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    SUBMIT_OUT="$(xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait 2>&1)" || true
    echo "$SUBMIT_OUT"
    rm -f "$ZIP"
    SUBMISSION_ID="$(printf '%s\n' "$SUBMIT_OUT" | awk '/id:/{print $2; exit}')"
    if printf '%s\n' "$SUBMIT_OUT" | grep -q "status: Accepted"; then
        echo "==> Stapling ticket to the app"
        xcrun stapler staple "$APP"
        xcrun stapler validate "$APP" && echo "    app staple OK"
    else
        echo "==> NOTARIZATION FAILED — fetching the detailed issue log:"
        [[ -n "$SUBMISSION_ID" ]] && xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_ARGS[@]}" || true
        exit 1
    fi
fi

# ----------------------------------------------------------------------------
# Package DMG (from the now-stapled app)
# ----------------------------------------------------------------------------
echo "==> Staging DMG layout"
STAGE="dist/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating DMG"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGE"

# Code-sign the DMG itself. Notarizing without this leaves the .dmg "not signed
# at all", so Gatekeeper rejects the download ("no usable signature") even
# though a ticket is stapled. Signing must happen BEFORE notarization.
if [[ "$NOTARIZABLE" == "1" ]]; then
    echo "==> Signing the DMG"
    codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"
fi

# ----------------------------------------------------------------------------
# Notarize + staple the DMG itself, so the downloaded .dmg also opens cleanly
# (the app-staple above covers the app once installed; this covers the download).
# ----------------------------------------------------------------------------
if [[ "$HAVE_NOTARY" == "1" ]]; then
    echo "==> Notarizing the DMG (this can take a few minutes)…"
    SUBMIT_OUT2="$(xcrun notarytool submit "$DMG_PATH" "${NOTARY_ARGS[@]}" --wait 2>&1)" || true
    echo "$SUBMIT_OUT2"
    SUBMISSION_ID2="$(printf '%s\n' "$SUBMIT_OUT2" | awk '/id:/{print $2; exit}')"
    if printf '%s\n' "$SUBMIT_OUT2" | grep -q "status: Accepted"; then
        echo "==> Stapling the DMG"
        xcrun stapler staple "$DMG_PATH"
        xcrun stapler validate "$DMG_PATH" && echo "    dmg staple OK"
    else
        echo "==> DMG NOTARIZATION FAILED — fetching the detailed issue log:"
        [[ -n "$SUBMISSION_ID2" ]] && xcrun notarytool log "$SUBMISSION_ID2" "${NOTARY_ARGS[@]}" || true
        exit 1
    fi
elif [[ "$NOTARIZABLE" == "1" ]]; then
    echo "==> NOTE: signed with Developer ID but NOT notarized (no notary creds)."
else
    echo "==> NOTE: ad-hoc build — users need right-click -> Open on first launch."
fi

echo "==> Done: ${DMG_PATH}"
ls -lh "$DMG_PATH"
