#!/usr/bin/env bash
# Build a distributable Transcribe.app: archive, sign with Developer ID,
# notarize, staple, zip, sign the zip for Sparkle, and write the appcast.
#
#   scripts/build-release.sh 1.2.0
#
# Produces, in dist/:
#   Transcribe-<version>.zip   the app, notarized and stapled
#   appcast.xml                Sparkle feed announcing this version
#
# Environment:
#   BUILD_NUMBER            CFBundleVersion. Must grow with every release, since
#                           it is what Sparkle compares. Default: commit count.
#   NOTARY_KEY_PATH         App Store Connect API key (.p8) for notarytool,
#   NOTARY_KEY_ID           with its key ID and issuer ID. Without them the
#   NOTARY_ISSUER_ID        build is not notarized (fine for local testing only:
#                           Gatekeeper and Homebrew will refuse it).
#   SPARKLE_KEY_PATH        EdDSA private key file for sign_update. Without it
#                           the key is read from the login Keychain.
#   SIGNING_IDENTITY        Default "Developer ID Application".
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/build-release.sh <version>}"
VERSION="${VERSION#v}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"
TEAM_ID="7UB7J68BJQ"
REPO="markcipolla/transcribe"
DERIVED=".build/xcode"
ARCHIVE=".build/release/Transcribe.xcarchive"
EXPORT=".build/release/export"
DIST="dist"
ZIP="$DIST/Transcribe-$VERSION.zip"

step() { printf '\n==> %s\n' "$*"; }

if grep -q 'SPARKLE_PUBLIC_KEY: ""' project.yml; then
    echo "error: SPARKLE_PUBLIC_KEY is empty in project.yml. Run 'make sparkle-key' and paste the" >&2
    echo "       public key in, or this build could never receive an update. See RELEASING.md." >&2
    exit 1
fi

rm -rf .build/release "$DIST"
mkdir -p .build/release "$DIST"

step "Generating project"
xcodegen generate --quiet

step "Archiving $VERSION ($BUILD_NUMBER)"
xcodebuild archive \
    -project Transcribe.xcodeproj -scheme Transcribe -configuration Release \
    -derivedDataPath "$DERIVED" -archivePath "$ARCHIVE" -skipPackagePluginValidation \
    ARCHS=arm64 \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    -quiet

step "Exporting with $IDENTITY"
cat > .build/release/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>$IDENTITY</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist .build/release/ExportOptions.plist -quiet
APP="$EXPORT/Transcribe.app"
codesign --verify --deep --strict "$APP"

if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
    step "Notarizing"
    ditto -c -k --keepParent "$APP" .build/release/notarize.zip
    xcrun notarytool submit .build/release/notarize.zip \
        --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
        --wait --timeout 30m
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose "$APP"
else
    echo "warning: NOTARY_KEY_PATH not set; this build is NOT notarized." >&2
fi

step "Zipping"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

step "Signing for Sparkle"
if [[ -n "${SPARKLE_KEY_PATH:-}" ]]; then
    SIGNATURE="$(scripts/sparkle-tool.sh sign_update --ed-key-file "$SPARKLE_KEY_PATH" "$ZIP")"
else
    SIGNATURE="$(scripts/sparkle-tool.sh sign_update "$ZIP")"
fi

step "Writing appcast"
MINIMUM_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
PUBLISHED="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
# The feed URL is .../releases/latest/download/appcast.xml, so each release
# carries a feed naming only itself; Sparkle only needs the newest item.
cat > "$DIST/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Transcribe</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUBLISHED</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM_OS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/Transcribe-$VERSION.zip"
                 type="application/octet-stream"
                 $SIGNATURE />
    </item>
  </channel>
</rss>
XML

step "Done"
shasum -a 256 "$ZIP"
ls -l "$DIST"
