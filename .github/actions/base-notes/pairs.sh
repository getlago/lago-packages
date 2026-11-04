#!/usr/bin/env bash
# Prints one describe.sh JSON line per lago-packages base that a PR moves:
# a unified diff on stdin, with the old ref on a removed line and the new ref
# on an added line. A base pinned on two old tags (two Dockerfiles) gives two
# pairs.
set -euo pipefail

ref='ghcr\.io/getlago/[a-z0-9._-]+:[0-9]{8}-r[0-9]+'
diff=$(cat)
refs() { grep -E "^[$1][^$1]" <<<"$diff" | grep -oE "$ref" | sort -u || true; }
old=$(refs -)
new=$(refs +)

while read -r image; do
  [[ -n $image ]] || continue
  repository=${image%:*}
  while read -r before; do
    [[ -n $before && ${before%:*} == "$repository" && $before != "$image" ]] || continue
    jq -nc --arg repository "$repository" --arg old "${before##*:}" --arg tag "${image##*:}" \
      '{repository: $repository, old: $old, tag: $tag, base: "\($repository):\($tag)"}'
  done <<<"$old"
done <<<"$new"
