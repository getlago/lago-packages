# lago-packages

Hardened [Wolfi](https://github.com/wolfi-dev)-based base images for Lago, built
with [apko](https://github.com/chainguard-dev/apko) and published to GHCR.

These images carry no shell history, no apt, no distro cruft. Every package has
an SBOM, and every image is signed with cosign (keyless, via GitHub OIDC).

## Images

| Image | Contents | Consumed by |
| --- | --- | --- |
| `ghcr.io/getlago/lago-api-base` | ruby-4.0, jemalloc, libpq, pdfcpu, git, postgresql-client | runtime stage of `lago-api`'s `Dockerfile.staging` |
| `ghcr.io/getlago/lago-api-build` | ruby-4.0 + headers, build-base, rust, nodejs, clang-19 | build stage of `lago-api`'s `Dockerfile.staging` |

Both are multi-arch (`x86_64`, `aarch64`).

## Tags

- `:<commit-sha>` — immutable, one artifact forever. Pin to this for reproducible builds.
- `:latest` — moves with `main`. Rebuilt daily so it stays within ~24h of upstream Wolfi.

The daily rebuild is the point: Wolfi publishes CVE patches multiple times a day,
and `:latest` picks them up without anyone opening a PR.

## Verifying

```sh
cosign verify ghcr.io/getlago/lago-api-base:latest \
  --certificate-identity-regexp '^https://github.com/getlago/lago-packages/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Adding an image

Drop a new `apko/<name>.yaml` in. The build matrix is derived from `apko/*.yaml`,
so it needs no workflow change — the image publishes to `ghcr.io/getlago/<name>`.

Set `org.opencontainers.image.source` to this repository. GHCR uses that
annotation to link the package back to its source, which is what inherits repo
permissions and makes provenance visible on the package page.

## Build pipeline

`apko build` produces a local multi-arch OCI tarball, Trivy scans that tarball
for fixable HIGH/CRITICAL CVEs, and only then does crane push the *exact* bytes
that were scanned. There is no rebuild between scan and push, so nothing can
drift into the registry unscanned.
