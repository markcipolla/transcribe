DERIVED := .build/xcode
# Release by default: in a Debug build the Voz SDK's dependencies are
# unoptimized, and its one-time SHA-256 check of the 467 MB model takes minutes.
CONFIG ?= Release
APP := $(DERIVED)/Build/Products/$(CONFIG)/Transcribe.app
PACKAGE := Packages/TranscribeKit

.PHONY: project open build run test test-core sparkle-key release clean

## project: generate Transcribe.xcodeproj from project.yml (needs `brew install xcodegen`)
project:
	xcodegen generate --quiet

## open: generate the project and open it in Xcode
open: project
	open Transcribe.xcodeproj

## build: build the app (CONFIG=Debug for a debug build)
build: project
	xcodebuild -project Transcribe.xcodeproj -scheme Transcribe -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) -skipPackagePluginValidation ARCHS=arm64 build -quiet

## run: build and launch the app
run: build
	-pkill -x Transcribe
	open $(APP)

## test: all package tests (macOS)
test:
	swift test --package-path $(PACKAGE)

## test-core: only the platform-independent tests, as CI runs them on Linux
test-core:
	swift test --package-path $(PACKAGE) --filter TranscribeCoreTests

## sparkle-key: create (or show) the EdDSA key that signs updates; prints the public key
sparkle-key: project
	@scripts/sparkle-tool.sh generate_keys

## release: build a signed, notarized release into dist/ locally (CI does this on tag push; see RELEASING.md)
release:
	scripts/build-release.sh $(VERSION)

clean:
	rm -rf .build $(PACKAGE)/.build Transcribe.xcodeproj
