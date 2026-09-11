# Transcribe

A menu bar app for macOS that notices when you join a Google Meet, Microsoft
Teams or Slack huddle call, transcribes it on your Mac with
[Voz](https://desertant.com/models/voz/), and saves the transcript as Markdown in
a folder you choose. Audio never leaves the Mac.

```sh
brew install --cask markcipolla/tap/transcribe
```

Requires an Apple silicon Mac on macOS 14.4 or later. Updates install
themselves via Sparkle.

Releases are self-signed rather than notarized, so macOS blocks a copy
downloaded from the releases page. The cask clears that for you. For a manual
download, run `xattr -dr com.apple.quarantine /Applications/Transcribe.app` once.

## How it works

**Detecting a call.** Every two seconds the app asks Core Audio which processes
have the microphone open. No permission is needed for that. A call keeps the
microphone open for its whole length, even while you are muted. When the process
is the Teams or Slack app, that's a Teams call or a Slack huddle. When it's a
browser, the app reads the browser's tab list over AppleScript and looks for a
`meet.google.com/xxx-xxxx-xxx` tab (a Meet call, whose title becomes the
transcript's title), a Teams web tab or an `app.slack.com` tab.
Recording starts after two consecutive detections and stops 20 seconds after the
call lets go of the microphone. Recordings that catch no speech, such as a Meet
lobby you peeked into, are discarded.

**Capturing.** The other participants come from a Core Audio process tap on the
Mac's audio output. It needs the *System Audio Recording* permission, not Screen
Recording, and works the same on speakers or headphones. Your side comes from
the microphone. The two are transcribed separately, which is how the transcript
knows who spoke without any diarization. If you're on speakers, microphone turns
that just repeat the meeting audio are dropped as echo.

**Transcribing.** Audio is cut into ~30 second chunks at the quietest moment
near each boundary and handed to Voz, which runs on the Neural Engine at about
100× realtime. The transcript file is rewritten after every chunk, so it's
readable during the meeting and done within seconds of the end.

**Output.** One Markdown file per meeting, e.g.
`2026-09-11 0930 Google Meet - Weekly sync.md`:

```markdown
---
title: "Weekly sync"
date: 2026-09-11T09:30:00+10:00
platform: "Google Meet"
duration: 2530
status: complete
---

# Weekly sync
...
**[00:00:03] Others:** Morning, everyone. Shall we start with the release?

**[00:00:09] Mark:** Sure. We're down to four open bugs.
```

## Permissions

| Permission | Why | When it's asked |
| --- | --- | --- |
| Microphone | Your side of the call | First recording |
| System Audio Recording | Everyone else | First recording |
| Automation (per browser) | Reading tab URLs to recognise Meet, Teams and Slack | First call in that browser |
| Notifications | "Transcribing…" and "Transcript saved" | First launch |

## Development

```sh
brew install xcodegen
make run        # generate the Xcode project, build, launch
make test       # all package tests
make open       # open in Xcode
```

The code is in two layers:

- `Packages/TranscribeKit/Sources/TranscribeCore` holds the Foundation-only logic:
  chunking, speaker turns, echo removal, meeting classification and Markdown.
  It builds on Linux, which is what CI runs on the org's self-hosted runners.
- `Packages/TranscribeKit/Sources/TranscribeKit` has everything that needs a Mac:
  Core Audio capture, meeting detection, Voz.
- `Transcribe/` is the SwiftUI menu bar app.

`transcribe-cli` exercises the pipeline without the app:

```sh
swift run --package-path Packages/TranscribeKit -c release transcribe-cli file recording.m4a
swift run --package-path Packages/TranscribeKit -c release transcribe-cli detect
```

Releases are covered in [RELEASING.md](RELEASING.md) and CI in
[docs/self-hosted-ci.md](docs/self-hosted-ci.md).

## Credits

Speech recognition by [Voz](https://desertant.com/models/voz/) from Desert Ant
Labs, under the [Desert Ant Labs Source-Available License](https://license.desertant.com/1.0).
It's free below 100,000 monthly active devices. The model is built on NVIDIA
Parakeet TDT 0.6B v3 (CC BY 4.0). The SDK reports model loads, with an anonymous
device ID and no audio or text, to count active devices.
