#!/usr/bin/env bash
# Tests the section headings of describe.sh with crane and trivy that fail:
# no registry, no network. Run: .github/actions/base-refresh/describe.test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
bin=$(mktemp -d)
trap 'rm -rf "$bin"' EXIT
printf '#!/bin/sh\nexit 1\n' >"$bin/crane"
printf '#!/bin/sh\nexit 1\n' >"$bin/trivy"
chmod +x "$bin/crane" "$bin/trivy"
fail=0

check() {
  local name=$1 want=$2 got
  got=$(PATH="$bin:$PATH" "$here/describe.sh" 2>&1 | grep -E '^#+ ')
  if [[ $got == "$want" ]]; then echo "ok   $name"; else
    echo "FAIL $name"; printf '  want:\n%s\n  got:\n%s\n' "$want" "$got"; fail=1
  fi
}

check "one pair has no image heading" "### What changed
### Why" <<'JSON'
{"repository":"ghcr.io/getlago/a-base","old":"20261103-r1","tag":"20261104-r2","base":"ghcr.io/getlago/a-base:20261104-r2"}
JSON

# shellcheck disable=SC2016 # the backticks are Markdown, not command substitution
check "two pairs name the image and both tags" '## `a-base`: `20261103-r1 → 20261104-r2`
#### What changed
#### Why
## `b-build`: `20261103-r3 → 20261104-r4`
#### What changed
#### Why' <<'JSON'
{"repository":"ghcr.io/getlago/a-base","old":"20261103-r1","tag":"20261104-r2","base":"ghcr.io/getlago/a-base:20261104-r2"}
{"repository":"ghcr.io/getlago/b-build","old":"20261103-r3","tag":"20261104-r4","base":"ghcr.io/getlago/b-build:20261104-r4"}
JSON

exit $fail
