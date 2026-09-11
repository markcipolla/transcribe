#!/usr/bin/env bash
# Write the Homebrew cask for a release into a checkout of markcipolla/homebrew-tap.
#
#   scripts/update-cask.sh <version> <zip-sha256> <tap-checkout-dir>
#
# Portable (bash + coreutils) so it runs on the Linux self-hosted runners.
set -euo pipefail

VERSION="${1:?version}"
VERSION="${VERSION#v}"
SHA256="${2:?sha256}"
TAP="${3:?tap directory}"

mkdir -p "$TAP/Casks"
cat > "$TAP/Casks/transcribe.rb" <<RUBY
# This file is written by markcipolla/transcribe's release workflow. Do not edit.
cask "transcribe" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/markcipolla/transcribe/releases/download/v#{version}/Transcribe-#{version}.zip"
  name "Transcribe"
  desc "On-device transcription of Google Meet and Microsoft Teams calls"
  homepage "https://github.com/markcipolla/transcribe"

  # The app updates itself with Sparkle; brew should not fight it.
  auto_updates true
  depends_on macos: :sonoma
  depends_on arch: :arm64

  app "Transcribe.app"

  # Releases are self-signed, not notarized, so Gatekeeper would refuse to open
  # a quarantined copy. Sparkle clears the flag on the updates it installs.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Transcribe.app"]
  end

  uninstall quit: "com.markcipolla.Transcribe"

  zap trash: [
    "~/Library/Caches/com.markcipolla.Transcribe",
    "~/Library/HTTPStorages/com.markcipolla.Transcribe",
    "~/Library/Preferences/com.markcipolla.Transcribe.plist",
  ]
end
RUBY
echo "Wrote $TAP/Casks/transcribe.rb for $VERSION"
