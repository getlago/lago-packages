#!/usr/bin/env bash
# Tests pairs.sh on hand-written diffs: no registry, no network.
# Run: .github/actions/base-notes/pairs.test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
fail=0

check() {
  local name=$1 want=$2 got
  got=$("$here/pairs.sh" | jq -r '"\(.repository) \(.old) \(.tag)"' | sort)
  if [[ $got == "$want" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name"; echo "  want: $want"; echo "  got:  $got"; fail=1
  fi
}

check "one base moves" "ghcr.io/getlago/gotenberg-base 20261103-r1322 20261104-r1414" <<'DIFF'
-ARG RUNTIME_IMAGE=ghcr.io/getlago/gotenberg-base:20261103-r1322@sha256:aaa
+ARG RUNTIME_IMAGE=ghcr.io/getlago/gotenberg-base:20261104-r1414@sha256:bbb
DIFF

check "one base on two old tags" "ghcr.io/getlago/front-base 20261023-r68 20261103-r1326
ghcr.io/getlago/front-base 20261029-r76 20261103-r1326" <<'DIFF'
-ARG RUNTIME_IMAGE=ghcr.io/getlago/front-base:20261029-r76@sha256:aaa
+ARG RUNTIME_IMAGE=ghcr.io/getlago/front-base:20261103-r1326@sha256:bbb
-ARG RUNTIME_IMAGE=ghcr.io/getlago/front-base:20261023-r68@sha256:ccc
+ARG RUNTIME_IMAGE=ghcr.io/getlago/front-base:20261103-r1326@sha256:bbb
DIFF

check "a longer name with the same prefix is another base" "ghcr.io/getlago/front-base 20261023-r68 20261103-r1326
ghcr.io/getlago/front-base-x 20261023-r1 20261103-r2" <<'DIFF'
-FROM ghcr.io/getlago/front-base:20261023-r68@sha256:aaa
+FROM ghcr.io/getlago/front-base:20261103-r1326@sha256:bbb
-FROM ghcr.io/getlago/front-base-x:20261023-r1@sha256:ccc
+FROM ghcr.io/getlago/front-base-x:20261103-r2@sha256:ddd
DIFF

check "context lines, file headers and other tags are ignored" "" <<'DIFF'
--- a/Dockerfile
+++ b/Dockerfile
 ARG RUNTIME_IMAGE=ghcr.io/getlago/api-base:20261103-r1@sha256:aaa
-FROM ghcr.io/getlago/api-base:latest
+FROM ghcr.io/getlago/api-base:sha-abc123
DIFF

check "a digest-only move of the same tag is not a pair" "" <<'DIFF'
-ARG RUNTIME_IMAGE=ghcr.io/getlago/api-base:20261103-r1@sha256:aaa
+ARG RUNTIME_IMAGE=ghcr.io/getlago/api-base:20261103-r1@sha256:bbb
DIFF

exit $fail
