# Releasing

Every merge to `main` ships a patch bump automatically once CI is green: the
release workflow reads the highest `v<major>.<minor>.<patch>` tag, adds one to
the patch, tags the merged commit, and runs the build. So `v0.2.0` becomes
`v0.2.1`, `v0.2.2`, and so on with no action beyond merging.

To bump major or minor, push a tag by hand:

```sh
git tag v0.3.0
git push origin v0.3.0
```

That releases `v0.3.0` immediately, and the next merge to `main` becomes
`v0.3.1`, then `v0.3.2`, and so on from that new line. Manual tag pushes skip
the CI-green gate on purpose — a hand-picked major/minor is deliberate.

`.github/workflows/release.yml` then:

1. **resolve** (self-hosted Linux) picks the version. For a tag push it's the
   tag; for a main push it's the latest `v` tag with the patch incremented,
   and the job pushes that new tag before the build starts.
2. **build** (GitHub-hosted `macos-26`) runs `scripts/build-release.sh`. It
   archives and signs with the certificate in `SIGNING_CERTIFICATE_P12`, zips,
   signs the zip with Sparkle's EdDSA key, and writes `appcast.xml`.
3. **publish** (self-hosted Linux) creates the GitHub release with the zip and
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

### 2. Signing certificate

Releases are signed with a self-signed certificate, `Transcribe Self-Signed`,
and are not notarized. That needs no Apple Developer Program membership. The
certificate doesn't satisfy Gatekeeper; it gives every build the same identity,
so macOS keeps the microphone, audio capture and Automation permissions across
updates. An ad-hoc signature would change with every build and reset them.

Because the app isn't notarized, Gatekeeper refuses a copy downloaded by hand.
The Homebrew cask removes the quarantine flag after installing, and Sparkle does
the same for the updates it installs.

The certificate lives in `~/keys/transcribe-signing.p12`, with its password in
`transcribe-signing.p12.password` next to it. Keep both in a password manager.
Losing them isn't fatal: a new certificate works, but installed copies ask for
their permissions again after the next update. To make one:

```sh
cat > cert.cnf <<'EOF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = Transcribe Self-Signed
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
PASS="$(openssl rand -base64 24)"
/usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -days 7300 -config cert.cnf \
  -keyout key.pem -out cert.pem
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -name "Transcribe Self-Signed" \
  -passout "pass:$PASS" -out ~/keys/transcribe-signing.p12
printf '%s' "$PASS" > ~/keys/transcribe-signing.p12.password
rm key.pem cert.pem cert.cnf
```

Use `/usr/bin/openssl` (LibreSSL): `security import` can reject the `.p12`
that OpenSSL 3 writes by default. Then add it as secrets:

```sh
base64 -i ~/keys/transcribe-signing.p12 | gh secret set SIGNING_CERTIFICATE_P12 --repo markcipolla/transcribe
gh secret set SIGNING_CERTIFICATE_PASSWORD --repo markcipolla/transcribe < ~/keys/transcribe-signing.p12.password
```

The hardened runtime is off in these builds. Its library validation refuses to
load a framework without a Team ID, and a self-signed certificate has none, so
the app would crash on launch.

### 3. Homebrew tap token

`HOMEBREW_TAP_GITHUB_TOKEN` is a token that can push to `markcipolla/homebrew-tap`.
It's the same secret name the Go tools' GoReleaser setup uses. A fine-grained
token scoped to that one repository with *Contents: read and write* is enough:

```sh
gh secret set HOMEBREW_TAP_GITHUB_TOKEN --repo markcipolla/transcribe
```

## Switching to Developer ID

With a paid Apple Developer Program membership, you can notarize instead. The
workflow signs as whatever certificate `SIGNING_CERTIFICATE_P12` holds. A
*Developer ID Application* certificate turns on the hardened runtime and a
Developer ID export. Installed copies take the switch as a normal update, since
Sparkle checks the EdDSA signature, not the certificate, but they ask for their
permissions once more because the app's identity changes.

1. Create the certificate in Xcode under Settings, Accounts, Manage
   Certificates, then export it from Keychain Access as a `.p12`:

   ```sh
   base64 -i DeveloperID.p12 | gh secret set SIGNING_CERTIFICATE_P12 --repo markcipolla/transcribe
   gh secret set SIGNING_CERTIFICATE_PASSWORD --repo markcipolla/transcribe
   ```

2. In App Store Connect, go to Users and Access, then Integrations, then App
   Store Connect API. Create a key with the *Developer* role and download the
   `.p8`:

   ```sh
   gh secret set NOTARY_API_KEY_P8 --repo markcipolla/transcribe < AuthKey_XXXXXXXXXX.p8
   gh secret set NOTARY_API_KEY_ID --repo markcipolla/transcribe --body XXXXXXXXXX
   gh secret set NOTARY_API_ISSUER_ID --repo markcipolla/transcribe --body <issuer-uuid>
   ```

3. The cask's quarantine removal can go.

## Building a release locally

Import the signing certificate into your login Keychain once:

```sh
security import ~/keys/transcribe-signing.p12 -T /usr/bin/codesign \
  -P "$(cat ~/keys/transcribe-signing.p12.password)"
```

Then:

```sh
make release VERSION=0.2.0
```

`dist/` gets the zip and `appcast.xml`, signed with the Sparkle key from your
Keychain.
