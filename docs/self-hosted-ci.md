# Self-hosted CI

transcribe is a **public** repository in an organisation with self-hosted
runners. It follows the same split as Shelvarr (see its `docs/self-hosted-ci.md`
for the full reasoning), which is designed so a fork can never put code on
those runners.

| Workflow | Trigger | Runner | Fork-reachable? |
| --- | --- | --- | --- |
| `ci.yml` ("CI") | `pull_request`, push to `main` | `ubuntu-latest` (container `swift:6.1`) and `macos-26` | **Yes**. This is the fork-facing gate |
| `ci-self-hosted.yml` ("CI (self-hosted)") | push to any branch, `workflow_dispatch` | `self-hosted` | No |
| `release.yml` | `v*` tags | `macos-26` for build, `self-hosted` for publish | No |

A `pull_request` run uses the fork's copy of the workflow file, so the
fork-facing workflow must never name `self-hosted`. Forks can't raise `push` or
tag events on this repository, and `workflow_dispatch` needs write access.

## What runs where

Every runner in the org is **Linux x64**. The app itself (Xcode, Core Audio,
Core ML, Voz) can only build on macOS, so:

- **Self-hosted:** `TranscribeCore`'s tests (chunking, speaker turns, echo
  removal, meeting classification, Markdown), plus the release's publish step
  (GitHub release, Homebrew cask).
- **GitHub-hosted macOS:** the app build, the macOS-only tests, and signing.
  macOS runners are free for public repositories.

`Packages/TranscribeKit/Package.swift` declares the Mac-only targets inside
`#if os(macOS)`. On Linux, `swift test` sees only `TranscribeCore` and never
fetches the Voz SDK.

Registering a Mac as a self-hosted runner would move the macOS jobs in-house
too. Put it in a runner group of its own, and give the jobs a label such as
`[self-hosted, macOS, ARM64]` so they never land on the Linux fleet.

## Runner group setup (one-time, org settings)

Runners are reached through the `public-ci` group (id 3): `visibility: selected`,
`allows_public_repositories: true`, holding `ci-runner-1` and `ci-runner-2`.
This repository is in it. A repository that isn't gets no error: its
self-hosted jobs just sit `queued`. The command that adds one is:

```sh
REPO_ID=$(gh api repos/markcipolla/transcribe --jq .id)
gh api -X PUT orgs/markcipolla/actions/runner-groups/3/repositories/$REPO_ID
```

`Default` must not be opened to public repositories. It holds the
socket-mounted `dokploy-runner-*` fleet.

## Swift on the runners

The `ci-runner-*` services (`HomeServer/github_runner.yml`) are
`myoung34/github-runner:ubuntu-noble` containers. Jobs run as root inside the
container, but the image carries no Swift and keeps no tool cache between jobs.
`swift-actions/setup-swift` doesn't work there, because it shells out to
`file`, which the image lacks. So `ci-self-hosted.yml` apt-installs Swift's
dependencies and fetches the swift.org toolchain on every run, verifying its
signature. That is an 879 MB download per run. Baking Swift into a public-runner
image would remove it. Keep that image free of anything private, since public
jobs run on it.
