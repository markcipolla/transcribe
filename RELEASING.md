# Releasing

```sh
git tag v0.2.0
git push origin v0.2.0
```

That's the whole release. `.github/workflows/release.yml` then:

1. **build** (GitHub-hosted `macos-26`) runs `scripts/build-release.sh`. It
   archives with Developer ID, notarizes and staples, zips, signs the zip with
   Sparkle's EdDSA key, and writes `appcast.xml`.
2. **publish** (self-hosted Linux) creates the GitHub release with the zip and
   `appcast.xml`, then writes `Casks/transcribe.rb` in
   [markcipolla/homebrew-tap](https://github.com/markcipolla/homebrew-tap).

Installed copies find the update through the feed in `Info.plist`,
`https://github.com/markcipolla/transcribe/releases/latest/download/appcast.xml`.
That URL always points at the newest release's `appcast.xml`. The build number
(`CFBundleVersion`) is the commit count, so it grows with every release.

## One-time setup

### 1. Sparkle signing key

```sh
make sparkle-key
```

This creates an EdDSA key pair in your login Keychain, or prints the existing
one, and shows the **public** key. Paste it into `project.yml` as
`SPARKLE_PUBLIC_KEY` and commit. Until you do, the updater stays switched off
and `build-release.sh` refuses to build.

Then export the private key for CI and add it as the `SPARKLE_PRIVATE_KEY`
repository secret:

```sh
scripts/sparkle-tool.sh generate_keys -x sparkle-private-key.txt
gh secret set SPARKLE_PRIVATE_KEY --repo markcipolla/transcribe < sparkle-private-key.txt
rm sparkle-private-key.txt
```

Back the key up somewhere safe, such as a password manager. Losing it means
existing installs can't verify future updates.

### 2. Developer ID certificate

Homebrew and Gatekeeper need a notarized app, and notarizing needs a
**Developer ID Application** certificate. An Apple Development certificate
isn't enough. Create one at developer.apple.com under Certificates, or in Xcode
under Settings, Accounts, Manage Certificates. Then export it from Keychain
Access as a `.p12`:

```sh
base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_CERTIFICATE_P12 --repo markcipolla/transcribe
gh secret set DEVELOPER_ID_CERTIFICATE_PASSWORD --repo markcipolla/transcribe
```

### 3. Notarization API key

In App Store Connect, go to Users and Access, then Integrations, then App Store
Connect API. Create a key with the *Developer* role and download the `.p8`:

```sh
gh secret set NOTARY_API_KEY_P8 --repo markcipolla/transcribe < AuthKey_XXXXXXXXXX.p8
gh secret set NOTARY_API_KEY_ID --repo markcipolla/transcribe --body XXXXXXXXXX
gh secret set NOTARY_API_ISSUER_ID --repo markcipolla/transcribe --body <issuer-uuid>
```

### 4. Homebrew tap token

`HOMEBREW_TAP_GITHUB_TOKEN` is a token that can push to `markcipolla/homebrew-tap`.
It's the same secret name the Go tools' GoReleaser setup uses. A fine-grained
token scoped to that one repository with *Contents: read and write* is enough:

```sh
gh secret set HOMEBREW_TAP_GITHUB_TOKEN --repo markcipolla/transcribe
```

## Building a release locally

With a Developer ID certificate in your Keychain:

```sh
NOTARY_KEY_PATH=~/keys/AuthKey.p8 NOTARY_KEY_ID=... NOTARY_ISSUER_ID=... \
  make release VERSION=0.2.0
```

Without the `NOTARY_*` variables the build isn't notarized. That's fine for
checking the pipeline, but not for distribution.
