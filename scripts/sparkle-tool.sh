#!/usr/bin/env bash
# Run one of Sparkle's command-line tools (generate_keys, sign_update, ...).
#
# They ship inside the Sparkle package that Xcode resolves, so this resolves
# packages into the same derived data the Makefile uses and runs the tool
# from there, keeping the tools in step with the framework version.
#
#   scripts/sparkle-tool.sh generate_keys        # create or print the EdDSA key
#   scripts/sparkle-tool.sh sign_update dist/Transcribe-1.0.0.zip
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED="${DERIVED_DATA:-.build/xcode}"
# `|| true`: before the first resolve the directory is missing, find fails, and
# pipefail would end the script silently.
find_bin() { find "$DERIVED/SourcePackages/artifacts" -type d -path "*Sparkle/bin" 2>/dev/null | head -1 || true; }

BIN="$(find_bin)"
if [[ -z "$BIN" ]]; then
    [[ -d Transcribe.xcodeproj ]] || xcodegen generate --quiet
    xcodebuild -resolvePackageDependencies -project Transcribe.xcodeproj -scheme Transcribe \
        -derivedDataPath "$DERIVED" -skipPackagePluginValidation >/dev/null
    BIN="$(find_bin)"
fi
[[ -n "$BIN" ]] || { echo "error: Sparkle tools not found under $DERIVED" >&2; exit 1; }

tool="$1"; shift
exec "$BIN/$tool" "$@"
