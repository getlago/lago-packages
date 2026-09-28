# syntax=docker/dockerfile:1
#
# Repackages the upstream metabase JAR onto a Wolfi + openjdk-21-jre
# base. Metabase is not built from source — the JAR comes down from
# downloads.metabase.com pinned to a specific version. Same pattern
# as lago-gotenberg's wrapper on the gotenberg-base image.
#
# BUILD ARGS
#   METABASE_VERSION — released tag on downloads.metabase.com (e.g.
#     v0.63.15). Set at build time by the workflow.
#   RUNTIME_IMAGE — the apko base to overlay onto. Defaults to :latest
#     which the daily rebuild in lago-packages keeps ~24h from Wolfi
#     upstream; pin to a commit SHA for reproducible / air-gapped builds.

ARG RUNTIME_IMAGE=ghcr.io/getlago/lago-metabase-base:latest
ARG METABASE_VERSION

FROM alpine:3 AS fetch
ARG METABASE_VERSION
RUN test -n "${METABASE_VERSION}" || (echo 'METABASE_VERSION build-arg is required' >&2 && exit 1)
RUN apk add --no-cache curl && \
    curl -fsSL --retry 3 --retry-delay 5 \
      -o /metabase.jar \
      "https://downloads.metabase.com/${METABASE_VERSION}/metabase.jar"

FROM ${RUNTIME_IMAGE}

LABEL org.opencontainers.image.source="https://github.com/getlago/lago-packages"
LABEL org.opencontainers.image.description="Repackaged upstream metabase JAR on the hardened lago-metabase-base image"
LABEL org.opencontainers.image.licenses="AGPL-3.0"

# The base image ships /home/nonroot as WORKDIR + owner. Copy the JAR
# as nonroot so the entrypoint (which runs as uid 65532) can read it.
COPY --from=fetch --chown=65532:65532 /metabase.jar /home/nonroot/metabase.jar

# No plugins/ directory on purpose. Metabase v0.50+ embeds every
# first-party database driver inside the uberjar (see the base image's
# comment on MB_PLUGINS_DIR being deliberately unset). If we ever need
# a community driver, add a `COPY --chown=65532:65532 my-driver.jar
# /home/nonroot/plugins/` here and set MB_PLUGINS_DIR at the same time
# — keeping the loaded classes in the image (and in the SBOM) instead
# of downloaded at runtime.

EXPOSE 3000

# Direct exec — no shell, no supervisor. Metabase runs Jetty in-JVM.
CMD ["java", "-jar", "/home/nonroot/metabase.jar"]
