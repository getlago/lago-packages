#!/usr/bin/env bash
# Rehashes the pinned downloads of the Dockerfiles given as arguments after
# Renovate moves an `ARG <NAME>_VERSION`. A pin is three lines:
#
#   # renovate: datasource=<datasource> depName=<package>
#   # sha256: <URL, ${VERSION} replaced by the version>
#   ARG <NAME>_VERSION=<version>
#
# and an `ARG <NAME>_SHA256=<hex>` line further down. Only versions that
# differ from $BASE_REF (default origin/main) are rehashed. An unchanged
# version keeps its hash: a mismatch there means the upstream bytes moved,
# and the Docker build fails on it.
set -euo pipefail
base=${BASE_REF:-origin/main}

for file in "$@"; do
  url=''
  mapfile -t lines <"$file"
  for line in "${lines[@]}"; do
    if [[ $line =~ ^#\ sha256:\ (.+)$ ]]; then
      url=${BASH_REMATCH[1]}
      continue
    fi
    [[ $line =~ ^ARG\ ([A-Z0-9_]+)_VERSION=(.+)$ ]] || { url=''; continue; }
    name=${BASH_REMATCH[1]} version=${BASH_REMATCH[2]}
    [[ -n $url ]] || continue
    old=$(git show "$base:$file" 2>/dev/null | sed -n "s/^ARG ${name}_VERSION=//p")
    if [[ $old == "$version" ]]; then
      url=''
      continue
    fi
    if [[ $(grep -c "^ARG ${name}_SHA256=" "$file") != 1 ]]; then
      echo "$file: no single ARG ${name}_SHA256 line" >&2
      exit 1
    fi
    src=${url//\$\{VERSION\}/$version}
    sum=$(curl -fsSL --retry 3 "$src" | sha256sum | cut -d' ' -f1)
    sed -i.bak "s/^ARG ${name}_SHA256=.*/ARG ${name}_SHA256=${sum}/" "$file" && rm -f "$file.bak"
    echo "$file: ${name} ${old:-new} -> ${version}, sha256 ${sum} (${src})"
    url=''
  done
done
