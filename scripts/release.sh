#!/usr/bin/env bash
#
# Build, sign, notarize, package, and Sparkle-sign a TOM release — locally.
#
# Produces, in dist/:
#   TOM-<version>.zip   signed + notarized app archive (this is what users download)
#   appcast.xml         Sparkle feed, EdDSA-signed
#
# ONE artifact serves both paths: the website's "Download" button hands out the
# zip (Safari auto-extracts it → drag TOM.app to /Applications), and Sparkle
# downloads the same zip to self-update. Because the app is notarized+stapled
# *inside* the zip, Gatekeeper validates it offline on first launch too.
#
# Upload BOTH files to https://meettom.ai/updates/ so they match SUFeedURL in
# Sources/TOM/Info.plist. The running app polls appcast.xml and offers the zip.
#
# Usage:
#   scripts/release.sh
#
# Steps before running:
#   1. Bump Sources/TOM/Resources/VERSION (e.g. v1.9.0).
#   2. Commit your work — the script refuses to run on a dirty tree.
#   3. Keep previous zips + appcast.xml in dist/ if you want the feed to retain
#      older versions (generate_appcast rebuilds the feed from whatever is in
#      dist/). A clean dist/ yields a feed with only the current version, which
#      is fine — Sparkle only needs the latest entry to offer an update.
#
# Optional env:
#   SPARKLE_BIN       path to Sparkle CLI bin/ (auto-detected from Xcode DerivedData)
#   NOTARY_PROFILE    notarytool keychain profile name (default tom-notary)
#
# One-time setup:
#   - Sparkle EdDSA key: already generated and stored in your login Keychain.
#     The matching public key lives in Info.plist (SUPublicEDKey). To inspect or
#     regenerate: <SPARKLE_BIN>/generate_keys  (then update SUPublicEDKey).
#   - notarytool profile: xcrun notarytool store-credentials tom-notary \
#       --apple-id "<id>" --team-id REPLACE-WITH-YOUR-APPLE-TEAM-ID --password "<app-specific-pw>"

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

DOWNLOAD_URL_PREFIX="https://meettom.ai/updates/"

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "release: working tree is dirty — commit or stash first" >&2
    exit 1
fi

VERSION="$(tr -d '[:space:]v' < Sources/TOM/Resources/VERSION)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "release: bad VERSION '$VERSION' — expected semver like 1.4.0" >&2
    exit 1
fi

BUILD="$(git rev-list --count HEAD)"

if [[ -f dist/appcast.xml ]] && grep -q "<sparkle:shortVersionString>$VERSION<" dist/appcast.xml; then
    echo "release: version $VERSION already in dist/appcast.xml — bump VERSION first" >&2
    exit 1
fi

# Locate the Sparkle CLI. It ships inside the Xcode-resolved Swift package; fall
# back to a manual ~/.sparkle/bin install if DerivedData isn't populated yet.
if [[ -z "${SPARKLE_BIN:-}" ]]; then
    SPARKLE_BIN="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -type d -path '*/artifacts/sparkle/Sparkle/bin' 2>/dev/null | head -1)"
fi
SPARKLE_BIN="${SPARKLE_BIN:-$HOME/.sparkle/bin}"
if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
    echo "release: generate_appcast not found under '$SPARKLE_BIN'." >&2
    echo "         Build the app once in Xcode (resolves Sparkle), or set SPARKLE_BIN." >&2
    exit 1
fi

NOTARY_PROFILE="${NOTARY_PROFILE:-tom-notary}"

echo "release: TOM $VERSION (build $BUILD)"
echo "release: sparkle CLI at $SPARKLE_BIN"

/usr/bin/sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $VERSION;/g" TOM.xcodeproj/project.pbxproj
/usr/bin/sed -i '' -E "s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $BUILD;/g" TOM.xcodeproj/project.pbxproj

# Drop the rolling "latest" copy before anything else so generate_appcast (which
# scans dist/ for archives) never mistakes it for a separate version.
rm -rf build dist/TOM.app
rm -f dist/TOM.zip
mkdir -p dist

xcodebuild -project TOM.xcodeproj -scheme TOM -configuration Release \
    -archivePath build/TOM.xcarchive archive

xcodebuild -exportArchive -archivePath build/TOM.xcarchive \
    -exportPath build/export -exportOptionsPlist scripts/ExportOptions.plist

codesign --verify --deep --strict --verbose=2 build/export/TOM.app

# notarytool requires a zip/pkg/dmg container — it rejects a bare .app. Zip the
# app for submission, wait for Apple to notarize, then staple the ticket onto
# the .app itself (a zip cannot be stapled). This submission zip is a throwaway;
# the distribution zip is rebuilt below from the *stapled* app.
NOTARIZE_ZIP="build/TOM-notarize.zip"
rm -f "$NOTARIZE_ZIP"
/usr/bin/ditto -c -k --keepParent build/export/TOM.app "$NOTARIZE_ZIP"
xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple build/export/TOM.app

# Package the stapled app into the distribution zip. --keepParent preserves the
# top-level TOM.app directory, so extraction yields TOM.app rather than its loose
# contents. The notarization ticket lives on the app *inside* the zip (a zip
# cannot itself be stapled), which is exactly what Sparkle expects and what lets
# Gatekeeper validate offline after extraction. No second notarization or
# codesign of the archive is needed — the app is already signed, notarized, and
# stapled.
#
# --norsrc --noextattr is CRITICAL: macOS Sequoia stamps every file with a
# `com.apple.provenance` xattr (unremovable via `xattr -c`). Without these flags
# ditto encodes each xattr as an AppleDouble `._name` entry in the zip. Finder's
# Archive Utility (the normal double-click path) and browser downloads extract
# those `._` files as real files inside the bundle, adding "unsealed contents" to
# Sparkle.framework and breaking the code-signature seal — Gatekeeper then reports
# the app as "damaged and can't be opened." Stripping xattrs from the archive
# leaves a clean bundle that Archive Utility extracts intact. (The code signature
# and stapled ticket are files inside the bundle, not xattrs, so both survive.)
ZIP_PATH="dist/TOM-$VERSION.zip"
rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr build/export/TOM.app "$ZIP_PATH"

# Guard: a single stray AppleDouble entry means the app will extract "damaged".
# Fail loudly here rather than shipping a zip that Gatekeeper rejects on the
# user's Mac (where we can't see it).
if unzip -l "$ZIP_PATH" | grep -qE '/\._|[[:space:]]\._[A-Za-z]'; then
    echo "release: FATAL — $ZIP_PATH contains AppleDouble (._) entries; extraction will break the code seal" >&2
    exit 1
fi

# EdDSA-sign the zip (key read from Keychain) and (re)build the appcast.
# generate_appcast scans dist/ for archives (.zip/.dmg), writes signed entries
# into appcast.xml, and points each download at DOWNLOAD_URL_PREFIX.
SPARKLE_DOWNLOAD_URL_PREFIX="$DOWNLOAD_URL_PREFIX" \
    "$SPARKLE_BIN/generate_appcast" dist/

# Stable filename for the website's "Download" button. Created AFTER the appcast
# so it isn't scanned as its own release.
cp "$ZIP_PATH" dist/TOM.zip

echo "release: artifacts ready in dist/"
ls -lh dist/
echo
echo "Upload to ${DOWNLOAD_URL_PREFIX} on meettom.ai:"
echo "  - dist/appcast.xml      (the Sparkle feed — in-app updates poll this)"
echo "  - $ZIP_PATH   (the versioned build the feed points at)"
echo "  - dist/TOM.zip   (stable URL for the website download button)"
