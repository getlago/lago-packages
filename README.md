# lago-packages

Hardened [Wolfi](https://github.com/wolfi-dev)-based base images for Lago, built
with [apko](https://github.com/chainguard-dev/apko) and published to GHCR, plus
the few [melange](https://github.com/chainguard-dev/melange) recipes that build
the apks Wolfi does not ship for us.

These images carry no shell history, no apt, no distro cruft. Every package has
an SBOM, and every image is signed with cosign (keyless, via GitHub OIDC).

## Images

| Image | Contents | Consumed by |
| --- | --- | --- |
| `ghcr.io/getlago/lago-api-base` | ruby-4.0, jemalloc, libpq, pdfcpu, git, postgresql-client, curl | runtime stage of `lago-api` |
| `ghcr.io/getlago/lago-api-build` | ruby-4.0 + headers, build-base, rust, nodejs, clang-19 | build stage of `lago-api` |
| `ghcr.io/getlago/lago-front-base` | nginx, unprivileged (binds an unprivileged port) | runtime stage of `lago-front` |
| `ghcr.io/getlago/lago-front-build` | nodejs, pnpm | build stage of `lago-front` |
| `ghcr.io/getlago/data-agent-base` | python-3.13, nonroot | runtime stage of `lago-data-agent` |
| `ghcr.io/getlago/data-agent-build` | python-3.13 + headers, uv, git, build-base | build + model-vendoring stages of `lago-data-agent` |
| `ghcr.io/getlago/events-processor-base` | minimal runtime | runtime stage of `events-processor` |
| `ghcr.io/getlago/events-processor-build` | go, rust, cargo | build stage of `events-processor` |
| `ghcr.io/getlago/gotenberg-base` | chromium, libreoffice-25.8, openjdk-21-jre, qpdf, exiftool, python-3.11, fonts | runtime stage of `lago-gotenberg` |
| `ghcr.io/getlago/gotenberg-build` | go-1.26, build-base, git | build stage of `lago-gotenberg` |
| `ghcr.io/getlago/lago-metabase-base` | openjdk-21-jre, fontconfig, Noto/Liberation fonts | runtime for the metabase JAR wrapper |
| `ghcr.io/getlago/lago-metabase` | above base + upstream metabase JAR (pinned in `dockerfiles/lago-metabase/METABASE_VERSION`) | metabase Deployment |
| `ghcr.io/getlago/license-base` | ruby-4.0, libpq, make | runtime stage of `lago-license` |
| `ghcr.io/getlago/license-build` | ruby-4.0 + headers, build-base, postgresql-dev, yaml-dev | build stage of `lago-license` |
| `ghcr.io/getlago/mcp-server-base` | libssl3, glibc, nonroot | runtime stage of `lago-mcp-server` |
| `ghcr.io/getlago/mcp-server-build` | rust, openssl-3.6 headers, pkgconf, build-base | build stage of `lago-mcp-server` |
| `ghcr.io/getlago/oauth-proxy-base` | ruby-4.0, make | runtime stage of `lago-oauth-proxy` |
| `ghcr.io/getlago/oauth-proxy-build` | ruby-4.0 + headers, build-base, yaml-dev | build stage of `lago-oauth-proxy` |
| `ghcr.io/getlago/ratelimit-service-base` | minimal static runtime (ca-certificates, tzdata) | runtime stage of `ratelimit-service` |
| `ghcr.io/getlago/ratelimit-service-build` | go-1.26 (CGO off) | build stage of `ratelimit-service` |
| `ghcr.io/getlago/rev-rec-base` | python-3.13, openjdk-17-jre, nonroot | both roles of the `rev-rec` Beam pipeline |
| `ghcr.io/getlago/rev-rec-build` | python-3.13 + headers, uv, build-base | build stage of `rev-rec` |
| `ghcr.io/getlago/self-billing-base` | python-3.13, nonroot, no shell | runtime stage of `lago-self-billing` |
| `ghcr.io/getlago/self-billing-build` | python-3.13, uv, busybox | build stage of `lago-self-billing` |
| `ghcr.io/getlago/superset-base` | python-3.12, libstdc++, nonroot, no shell | runtime stage of `data/superset` (lago-data `dashboards/`) |
| `ghcr.io/getlago/superset-build` | python-3.12 + headers, uv, build-base, openssl | build and dev stages of `data/superset` |
| `ghcr.io/getlago/sidekiq-web-base` | ruby-3.4, nonroot | runtime stage of `sidekiq-web` |
| `ghcr.io/getlago/sidekiq-web-build` | ruby-3.4 + headers, build-base, openssl-dev, yaml-dev | build stage of `sidekiq-web` |
| `ghcr.io/getlago/argo-workflows-server-base` | minimal runtime (ca-certificates, tzdata), argo uid 8737 | runtime stage of `argo-workflows-server` |
| `ghcr.io/getlago/argo-workflows-server-build` | go-1.26, nodejs-20, yarn, git, patch, make, bash, build-base | build stages of `argo-workflows-server` |
| `ghcr.io/getlago/zitadel-login-base` | nodejs-22, busybox, nonroot | runtime stage of the Lago-branded zitadel login app |
| `ghcr.io/getlago/zitadel-login-build` | nodejs-22, pnpm, git, patch, build-base | build stage of the zitadel login app |

All are multi-arch (`x86_64`, `aarch64`).

## Tags

- `:<YYYYMMDD>-r<run>` — immutable, one per publish. Pin to this (or to the digest) for reproducible builds.
- `:<commit-sha>` — immutable: set only the first time a commit publishes.
- `:latest` — the newest publish. Rebuilt daily so it stays within ~24h of upstream Wolfi.
- `:<YYYYMMDD>-r<run>-<arch>`, `:latest-<arch>` — the per-arch images behind the tags above.

The daily rebuild is the point: Wolfi publishes CVE patches multiple times a day,
and `:latest` picks them up without anyone opening a PR.

apko builds are reproducible, so a rebuild with the same apk set gives the same
digest. A base is published only when its digest changes. The `notify` job
then sends a `base-updated` `repository_dispatch` to `getlago/lago-deploy` and
`getlago/lago-infrastructure`. There, `base-refresh plan`
([lago-infrastructure `tools/base-refresh`](https://github.com/getlago/lago-infrastructure/tree/main/tools/base-refresh))
rebuilds the deployed images on the new digests and bumps their GitOps tags.

The dispatch needs the `BASE_UPDATE_DISPATCH_TOKEN` secret (a token with
`contents: write` on both repos). The consumers also run daily, so a missed
dispatch only delays a refresh.

## Verifying

```sh
cosign verify ghcr.io/getlago/lago-api-base:latest \
  --certificate-identity-regexp '^https://github.com/getlago/lago-packages/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

### SBOMs

apko emits an SPDX SBOM per arch on every build. Each one is attached to its
per-arch image as a cosign attestation, and uploaded as a workflow artifact
(90 days). Attest against the **per-arch** tag — that is the digest a puller
resolves to:

```sh
cosign verify-attestation --type spdxjson \
  ghcr.io/getlago/lago-api-base:latest-x86_64 \
  --certificate-identity-regexp '^https://github.com/getlago/lago-packages/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  | jq -r '.payload | @base64d | fromjson | .predicate.name'
```

## Adding an image

Drop a new `apko/<name>.yaml` in. The build matrix is derived from `apko/*.yaml`,
so it needs no workflow change — the image publishes to `ghcr.io/getlago/<name>`.

Set `org.opencontainers.image.source` to this repository. GHCR uses that
annotation to link the package back to its source, which is what inherits repo
permissions and makes provenance visible on the package page.

## The package overlay (`packages/`)

Wolfi carries almost everything our images need. `packages/` holds a melange
recipe for each exception — today only `chromium`, where Wolfi is months behind
the CVE fixes gotenberg needs, and `ruby-4.0`, which Wolfi has since caught up
on. Each recipe builds an apk for both arches, signed with the Lago melange key
and published to the private S3 bucket `lago-wolfi-packages`.

A manifest opts into the overlay by naming it as a repository:

```yaml
contents:
  repositories:
    - https://packages.wolfi.dev/os
    - ./repo-local
  keyring:
    - https://packages.wolfi.dev/os/wolfi-signing.rsa.pub
    - ./repo-local/lago-signing.rsa.pub
```

`./repo-local` is the marker the workflow greps for. A manifest without it never
assumes the AWS role and never downloads the overlay.

**apk installs the highest version it can see.** The overlay sits beside Wolfi,
it does not replace it, so a recipe only wins while its version is above Wolfi's.
That is deliberate for `chromium` and it is why the workflow's `aws s3 sync`
pulls an explicit allowlist of apks rather than the whole bucket.

### Changing a recipe

Edit `packages/<name>.yaml` and push. Two workflows run, in order:

1. `build-packages.yaml` builds the apk on both arches, re-signs the index and
   publishes to S3.
2. `build-bases.yaml` starts on `workflow_run` and rebuilds every manifest that
   names `./repo-local`.

So one merge produces the new `ghcr.io/getlago/<base>:<sha>` tag. Pin that tag in
the consuming repo and you are done.

The chaining is the point. Both workflows watch `main`, so a recipe push that
also touched `apko/` would otherwise rebuild the image beside the package build
and sync the apk the bucket held *before* the merge.

The daily cron rebuilds images only. A recipe pins one upstream version, so
rebuilding it on a timer would republish identical bytes.

### Key material

The signing key is a `tls.PrivateKey` owned by the `packages` Pulumi project in
`getlago/lago-infrastructure`. That project generates it, mirrors it to
1Password, writes the private half to this repo as the `MELANGE_SIGNING_KEY`
Actions secret, publishes the public half to `s3://lago-wolfi-packages/os/` for
apko's keyring, and publishes the bucket role ARN here as `PACKAGES_ROLE_ARN`.
Nothing in this repo creates or rotates it.

## Build pipeline

`build-packages.yaml` builds apks, `build-bases.yaml` builds images and chains
off it. Inside `build-bases.yaml`, `discover` picks the manifests this event
needs and `build` runs the matrix over them.

`apko build` produces a local multi-arch OCI tarball, Trivy scans that tarball
for fixable HIGH/CRITICAL CVEs, and only then does crane push the *exact* bytes
that were scanned. There is no rebuild between scan and push, so nothing can
drift into the registry unscanned.

### Ignoring fixable CVEs that Wolfi hasn't shipped yet

Sometimes Trivy flags a CVE as fixable because upstream released a patched
version, but Wolfi hasn't packaged it into its apk repo yet (typical on
fast-moving trees like `chromium`). Drop those CVE IDs into
`.trivyignore.d/<manifest-name>` and Trivy will treat them as accepted
exceptions on both arches until the next successful rebuild.

Every entry needs a comment explaining the source of the CVE and the trigger
that clears it (usually "Wolfi bumps `<package>` past `<version>`"). Trivy
silently skips ignore IDs that don't match any current finding, so prune the
file whenever the daily rebuild passes cleanly.
