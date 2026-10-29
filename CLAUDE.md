# CLAUDE.md

Repo-specific guidance for Claude Code (and humans) working on `lago-packages`.

## What this repo is

Hardened Wolfi-based base images and thin wrappers around upstream binaries,
built with [apko](https://github.com/chainguard-dev/apko), scanned with Trivy,
and signed with cosign. Everything published here is on the Lago cloud pod
supply chain, so this repo is treated as security-critical.

## No unverified downloads — the one non-negotiable rule

Every network fetch that lands bytes into a published image must be verified
against a pinned identity before those bytes are used. That means:

- **`curl` / `wget` in any Dockerfile:** the fetched artifact must be piped
  into `sha256sum -c -` (or `cosign verify` for OCI content) in the same
  `RUN` layer, against a hash committed to this repo. No exceptions —
  a curl without a verification step is a build error waiting for a
  supply-chain incident.
- **`git clone` of upstream sources:** pin a tag or a full commit SHA in
  the `--branch` / `git checkout` step. Never track a moving ref
  (`main`, `master`, `latest`).
- **`apko` package installs:** pinned by Wolfi's own signed apkindex.
  The apko manifest doesn't need per-package hashes — but the base
  repository URL in `contents.repositories` and the keyring URL in
  `contents.keyring` MUST NOT be edited without a security review.
- **Base image references** (`FROM …:latest` / `ARG *_IMAGE`): the daily
  rebuild in `build-bases.yaml` publishes `:latest` with cosign
  signatures. Downstream Dockerfiles pin either `:latest` (trusting the
  daily gate) or a `:<commit-sha>` tag from this repo — both are signed.
  Never pull a base from a registry outside `ghcr.io/getlago/*`,
  `cgr.dev/chainguard/*`, or `packages.wolfi.dev` without adding a
  cosign verification step.

The pattern to follow lives in `dockerfiles/lago-metabase/Dockerfile`:

```dockerfile
ARG METABASE_VERSION
ARG METABASE_SHA256
RUN test -n "${METABASE_SHA256}" || (echo 'METABASE_SHA256 required' >&2 && exit 1)
RUN curl -fsSL --retry 3 --retry-delay 5 \
      -o /metabase.jar \
      "https://downloads.metabase.com/${METABASE_VERSION}/metabase.jar" && \
    echo "${METABASE_SHA256}  /metabase.jar" | sha256sum -c -
```

Hashes live next to the version pin (`dockerfiles/lago-metabase/METABASE_SHA256`
sits next to `METABASE_VERSION`) so bumping the version and the hash is one
atomic commit. The build workflow reads both files and fails fast if either
is empty.

## When adding a new curl / wget fetch

1. Download the artifact once, locally, from the canonical URL.
2. `sha256sum <file>` — that string is the pin.
3. Commit the hash to the repo (a `*_SHA256` file next to the version pin,
   or an `ARG` default with the value inline for one-shot fetches).
4. Wire `sha256sum -c -` into the same `RUN` layer as the curl. Chain
   them with `&&` so a mismatch aborts the build before the artifact is
   used.
5. When the upstream version bumps, re-download → re-hash → commit both
   values together. If the upstream ships a signed checksum file, prefer
   downloading and verifying that instead of computing the hash yourself.

Signed upstream artifacts (GPG-signed release tarballs, cosign-signed
OCI content) should be verified with the upstream's public key or the
maintainer's OIDC identity — a SHA is the fallback, not the goal.

## When adding a new apko manifest

`build-bases.yaml` auto-discovers `apko/*.yaml`, so a new manifest gets
built, scanned by Trivy, and cosign-signed with no workflow change. Two
things to keep in mind:

- **Question every package.** Runtime bases only carry what the app
  actually consumes at runtime; build images only carry what
  `bundle install` / `go build` / `pnpm install` needs at build time.
  If a package showed up because the previous Debian Dockerfile
  installed it, that's not a reason to keep it. Check whether the
  installed binary is ever invoked (grep the source, `strings` the
  compiled binary) before shipping it.
- **No writable state directories.** A hardened image is immutable; a
  writable `/plugins`, `/opt/<app>/extensions`, or similar creates a
  runtime code-load surface not covered by the SBOM. If an upstream app
  loads plugins at runtime, bake the plugins in at build time and leave
  the directory read-only.

## Directory layout

- `apko/` — apko manifests. One file per published base image. Naming:
  `<image-name>.yaml` publishes to `ghcr.io/getlago/<image-name>`.
- `dockerfiles/<image>/` — wrapper Dockerfiles for images that need to
  overlay content the apko base can't fetch (e.g. `lago-metabase`
  copies the upstream JAR onto `lago-metabase-base`). Same
  verify-everything rule applies.
- `.github/workflows/build-bases.yaml` — the apko build pipeline. Do
  not edit without a security review — this is the gate that keeps
  unscanned bytes out of the registry.
- `.github/workflows/build-<image>.yaml` — per-wrapper build pipelines.
  Each one must Trivy-scan the built image before pushing and
  cosign-sign every tag it publishes.

## Publishing tags

- `:<commit-sha>` — immutable, from a single build. Pin here for
  reproducible / air-gapped consumers.
- `:latest` — moves with `main`, republished daily so it stays within
  ~24h of upstream Wolfi CVE patches.
- Wrapper images (metabase, gotenberg) also carry `:<upstream-version>`
  and `:<upstream-version>-<commit-sha>` alongside `:latest`.

Every published tag is cosign-signed keyless via GH OIDC. Consumers
should verify with:

```sh
cosign verify ghcr.io/getlago/<image>:<tag> \
  --certificate-identity-regexp '^https://github.com/getlago/lago-packages/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```
