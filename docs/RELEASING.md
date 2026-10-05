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
