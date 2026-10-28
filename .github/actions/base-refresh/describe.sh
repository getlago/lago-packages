#!/usr/bin/env bash
# Prints the "what changed and why" part of a bump PR body, in Markdown, for
# one image: plan.sh JSON lines on stdin (pins of one image share the tags).
# What: the apk packages of the base layers, old image against new image.
# Why: the OS CVEs (Trivy, any severity) the new image no longer has.
# Best effort: a failed lookup prints a note, never fails the bump.
# Needs jq, crane and trivy, logged in to the registry.
set -uo pipefail

# Prints "<package> <version>" lines of the apk database in the first $2
# layers of image $1 (linux/amd64). The database is in the base layers.
packages() {
  local layers db=
  layers=$(crane manifest --platform linux/amd64 "$1" | jq -r '.layers[].digest' | head -n "$2") || return 1
  for layer in $layers; do
    # tar fails on the path the layer does not have, but prints the other.
    found=$(crane blob "${1%:*}@$layer" | tar -xzOf - usr/lib/apk/db/installed lib/apk/db/installed 2>/dev/null || true)
    [[ -n $found ]] && db=$found
  done
  [[ -n $db ]] || return 1
  awk -F: '/^P:/ {p = $2} /^V:/ {print p, $2}' <<<"$db" | sort
}

# Prints "<id> <severity> <package>" lines, one per OS finding.
cves() {
  trivy image --quiet --scanners vuln --pkg-types os --format json "$1" |
    jq -r '.Results[]?.Vulnerabilities[]? | "\(.VulnerabilityID) \(.Severity) \(.PkgName)"' | sort -u
}

# "<id> <severity> <package>" lines in, one Markdown item per CVE out.
by_cve() {
  awk '{sev[$1] = $2; pkgs[$1] = pkgs[$1] (pkgs[$1] ? ", " : "") "`" $3 "`"}
    END {for (id in sev) printf "- %s (%s): %s\n", id, sev[id], pkgs[id]}' | sort | head -n 50
}

pin=$(head -n1)
repository=$(jq -r .repository <<<"$pin")
old=$repository:$(jq -r .old <<<"$pin")
new=$repository:$(jq -r .tag <<<"$pin")
base=$(jq -r .base <<<"$pin")
tmp=$(mktemp -d)

echo "### What changed"
echo
echo "New base: \`$base\`."
echo
n=$(crane config "$base" | jq '.rootfs.diff_ids | length' 2>/dev/null)
if [[ -n $n ]] && packages "$old" "$n" >"$tmp/old" && packages "$new" "$n" >"$tmp/new"; then
  join -a1 -a2 -e '-' -o 0,1.2,2.2 "$tmp/old" "$tmp/new" | awk '$2 != $3' >"$tmp/diff"
  if [[ -s $tmp/diff ]]; then
    echo "| Base package | Old | New |"
    echo "| --- | --- | --- |"
    awk '{printf "| `%s` | %s | %s |\n", $1, $2, $3}' "$tmp/diff"
  else
    echo "No apk package changed: the base moved for another reason (file or metadata change)."
  fi
else
  echo "Could not read the apk database of the base layers."
fi

echo
echo "### Why"
echo
if cves "$old" >"$tmp/cve-old" && cves "$new" >"$tmp/cve-new"; then
  fixed=$(comm -23 "$tmp/cve-old" "$tmp/cve-new")
  added=$(comm -13 "$tmp/cve-old" "$tmp/cve-new")
  if [[ -n $fixed ]]; then
    echo "Fixes $(cut -d' ' -f1 <<<"$fixed" | sort -u | wc -l | tr -d ' ') OS CVEs (Trivy, old image against new image):"
    echo
    by_cve <<<"$fixed"
  else
    echo "Fixes no OS finding. It keeps the image on the current base, so the next fix lands with no extra build."
  fi
  if [[ -n $added ]]; then
    echo
    echo "New OS CVEs in the new image:"
    echo
    by_cve <<<"$added"
  fi
  echo
  echo "Still open in the new image: $(grep -cE ' (HIGH|CRITICAL) ' "$tmp/cve-new") HIGH/CRITICAL and $(grep -c . "$tmp/cve-new") total OS findings."
else
  echo "Could not scan the old and new images with Trivy."
fi
rm -rf "$tmp"
exit 0
