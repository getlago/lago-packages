#!/usr/bin/env bash
# Writes one image's part of the daily bump PR into directory $1: the
# Markdown section (section.md) and its summary row (summary.tsv). The
# image's pins (plan.sh JSON lines) come on stdin and are kept (pins.jsonl).
# Needs jq, crane and trivy, logged in to the registry (describe.sh).
set -euo pipefail

out=$1
mkdir -p "$out"
cat >"$out/pins.jsonl"
name=$(jq -r .name <"$out/pins.jsonl" | head -n1)

{
  echo "## \`$name\`"
  echo
  jq -r '"- `\(.file)` `\(.path)`: `\(.old)` → `\(.tag)`"' <"$out/pins.jsonl"
  echo
  # describe.sh owns the What/Why; demote its headings under the image's.
  describe.sh <"$out/pins.jsonl" | sed -E 's/^(#{2,3}) /#\1 /'
  echo
  # The run that published each new base, as bump.sh did per image.
  for base in $(jq -r .base <"$out/pins.jsonl" | sort -u); do
    run=$(crane manifest "$base" 2>/dev/null | jq -r '.annotations["dev.getlago.build-run"] // empty' 2>/dev/null || true)
    run=${run:-${TRIGGER_URL:-}}
    if [[ -n $run ]]; then echo "Base build (\`${base%@*}\`): $run"; fi
  done
} >"$out/section.md"

# One row per old -> new pair. The fixed count comes from describe.sh's
# "Fixes N OS CVEs" line: 0 when it fixes none, ? when the scan failed.
fixed=$(grep -oE '^Fixes [0-9]+ OS CVEs' "$out/section.md" | grep -oE '[0-9]+' | paste -sd+ - | bc 2>/dev/null || true)
if [[ -z $fixed ]]; then
  if grep -q '^Fixes no OS finding' "$out/section.md"; then fixed=0; else fixed='?'; fi
fi
jq -r --arg fixed "$fixed" '[.name, .old, .tag, $fixed] | @tsv' <"$out/pins.jsonl" | sort -u >"$out/summary.tsv"
