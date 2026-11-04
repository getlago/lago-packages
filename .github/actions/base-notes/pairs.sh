#!/usr/bin/env bash
# Prints one describe.sh JSON line per lago-packages base that a PR moves:
# a unified diff on stdin. Within each hunk, the k-th removed ref of a base
# pairs with its k-th added ref, as an in-place edit lists them, so two
# Dockerfiles moved to different tags never pair across.
set -euo pipefail

awk '
  function flush(  key, i) {
    for (key in nold) {
      for (i = 1; i <= nold[key] && i <= nnew[key]; i++)
        if (old[key, i] != new[key, i]) print key, old[key, i], new[key, i]
    }
    split("", nold); split("", nnew); split("", old); split("", new)
  }
  # refs end at the digest, a quote, a space or the line end: an -aarch64 tag
  # is another image.
  function refs(line, sign,  ref, rest, next_char, repository) {
    while (match(line, /ghcr\.io\/getlago\/[a-z0-9._-]+:[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-r[0-9]+/)) {
      ref = substr(line, RSTART, RLENGTH)
      rest = substr(line, RSTART + RLENGTH)
      next_char = substr(rest, 1, 1)
      if (next_char == "" || next_char ~ /[@ \t"\047]/) {
        repository = ref; sub(/:[^:]*$/, "", repository)
        if (sign == "-") old[repository, ++nold[repository]] = substr(ref, length(repository) + 2)
        else new[repository, ++nnew[repository]] = substr(ref, length(repository) + 2)
      }
      line = rest
    }
  }
  /^(--- |\+\+\+ |@@|diff )/ { flush(); next }
  /^[-+]/ { line = substr($0, 2); sub(/\r$/, "", line); refs(line, substr($0, 1, 1)) }
  END { flush() }
' | sort -u | while read -r repository before after; do
  jq -nc --arg repository "$repository" --arg old "$before" --arg tag "$after" \
    '{repository: $repository, old: $old, tag: $tag, base: "\($repository):\($tag)"}'
done
