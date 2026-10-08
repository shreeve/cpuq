# Releasing

A release is a `vX.Y.Z` tag. GitHub Actions does the rest
(`.github/workflows/release.yml`), and the Homebrew formula follows by hand.

| Piece | Where | Does |
| --- | --- | --- |
| Version | `build.zig.zon` | The one place the version lives. `cpuq --version` reports it; a release build stamps it with `-Dversion`. |
| Notes | `CHANGELOG.md` | The `## X.Y.Z — date` section is the release's notes. |
| Release | `release.yml` | Checks the tag against `build.zig.zon` and the changelog, runs the unit and end-to-end tests on Linux and macOS, builds four targets in safe mode, packs them (`scripts/package-release.sh`), writes and cosign-signs the checksums, and publishes the release. |
| Install | `install.sh` | Fetched from `main`; installs the latest release, or a pinned tag, after checking its sha256. |
| Homebrew | `shreeve/homebrew-tap`, `Formula/cpuq.rb` | One archive per platform; `scripts/bump-homebrew-formula.py` points it at a release. |

Every release publishes:

    cpuq-vX.Y.Z-{osx-arm64,osx-amd64,linux-amd64,linux-arm64}.tar.gz
    cpuq-vX.Y.Z-checksums.txt
    cpuq-vX.Y.Z-checksums.txt.bundle

Each archive unpacks to `cpuq-vX.Y.Z-<plat>/` with `cpuq`, `README.md`,
`CHANGELOG.md` and `LICENSE`. The Linux binaries are static (musl); the
macOS ones link libSystem only and carry the linker's ad-hoc signature.

## Cutting a release

1. Set `.version` in `build.zig.zon` to `X.Y.Z`, and turn the changelog's
   top section into `## X.Y.Z — <date>`. Commit both on `main` and push;
   wait for CI to pass.
2. Tag and push the tag:

       git tag vX.Y.Z && git push origin vX.Y.Z

   Watch it with `gh run watch`. A tag that does not match `build.zig.zon`,
   or has no changelog section, fails before anything is built.
3. Point the formula at the release, in a checkout of the tap beside this
   repository:

       gh release download vX.Y.Z -R shreeve/cpuq -p 'cpuq-vX.Y.Z-checksums.txt' -D /tmp
       scripts/bump-homebrew-formula.py ../homebrew-tap/Formula/cpuq.rb X.Y.Z /tmp/cpuq-vX.Y.Z-checksums.txt

   Commit it on a branch of the tap, open a pull request, and merge it with
   `gh pr merge --squash --delete-branch`.

A tag with a suffix (`v1.2.0-rc.1`) publishes a prerelease, which
`install.sh` installs only when asked for by tag.

## Verifying a release

    gh release view vX.Y.Z -R shreeve/cpuq
    curl -fsSL https://raw.githubusercontent.com/shreeve/cpuq/main/install.sh | BIN=/tmp/cpuq-check bash
    /tmp/cpuq-check/cpuq --version
    brew update && brew install shreeve/tap/cpuq && brew test cpuq

The checksums are signed with cosign keyless, by this repository's release
workflow:

    cosign verify-blob cpuq-vX.Y.Z-checksums.txt \
      --bundle cpuq-vX.Y.Z-checksums.txt.bundle \
      --certificate-identity "https://github.com/shreeve/cpuq/.github/workflows/release.yml@refs/tags/vX.Y.Z" \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com

## If something goes wrong

- **The workflow failed before publishing.** Fix it on `main`, then move
  the tag: `git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z`, tag
  again and push.
- **A bad release is out.** Publish a fixed, higher version; `install.sh`
  and the formula follow the newest one.

## Cpuq.app

The menu-bar app is released on its own, as `app-vX.Y.Z`, with its own changelog
(`app/CHANGELOG.md`); [app/README.md](../app/README.md) describes how it updates. Paths and
commands below are relative to `app/`.

### One-time setup

- The Developer ID and the notarytool keychain profile `notary-tool` are the ones Shotts,
  Transfer and DuckTable use:

      security find-identity -v -p codesigning   # lists "Developer ID Application: Steve Shreeve (SD6N7Z8P9P)"
      xcrun notarytool history --keychain-profile notary-tool

- The update key is an ed25519 key of Cpuq's own, under the keychain account `cpuq` (Shotts uses
  `shotts`, DuckTable `ducktable`, Transfer the default account; never delete or export a key by
  service alone, which would take them all). Its public half is `Support/sparkle-public-key.txt`
  and `SUPublicEDKey` in `Support/Info.plist`. The tools are in `.build/artifacts` after a build:

      bin=$(find .build/artifacts -type d -path '*Sparkle/bin' | head -1)
      $bin/generate_keys --account cpuq -p                      # must print Support/sparkle-public-key.txt
      $bin/generate_keys --account cpuq -x /tmp/cpuq-key        # export, to back it up; then rm /tmp/cpuq-key
      $bin/generate_keys --account cpuq -f /tmp/cpuq-key        # import it on another Mac

  Keep a backup of the private key in a password manager. Losing it strands every installed copy
  on its version, since an app trusts only the key it shipped with; anyone who has it can sign an
  update every installed copy will accept.

### Cutting an app release

Add the version's `## X.Y.Z — date` section to `CHANGELOG.md` (it is the release notes, and what
the update dialog shows), land it on `main`, then:

    scripts/release.sh X.Y.Z --dry-run   # builds, notarizes, staples, zips and signs the feed; publishes nothing
    scripts/release.sh X.Y.Z             # publishes app-vX.Y.Z and refreshes the cpuq-app-updates feed
    scripts/update-cask.sh X.Y.Z         # opens the tap's pull request for the cask; merge it

The release refuses to run without the Developer ID, the notary profile, a keychain key that
matches `Support/sparkle-public-key.txt`, or the changelog section; a real release also needs a
clean `main` in step with `origin/main`, a signed-in `gh`, and a version higher than the last
`app-v*` tag. Versions only go up: Sparkle orders updates by `CFBundleVersion`, which the release
sets to the version. A bad release is fixed by a higher one; deleting a release rolls no one back.
