#!/usr/bin/env bash
# Prints the "what changed and why" part of a bump PR body, in Markdown, for
# one image: plan.sh JSON lines on stdin. Pins of one name can sit on
# different deployed tags: each old -> new pair gets its own section.
# What: the apk packages of the base layers, old image against new image.
# Why: the OS CVEs (Trivy, any severity) the new image no longer has.
# Best effort: a failed lookup prints a note, never fails the bump.
# Needs jq, crane and trivy, logged in to the registry. NO_FIX_NOTE replaces
# the line for a new image that fixes no OS finding.
set -uo pipefail
# join needs the byte order that sort uses.
export LC_ALL=C

# packages() and cves() are shared with gate.sh.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

# "<id> <severity> <package>" lines in, one Markdown item per CVE out, at
# most 50 (a PR body holds 65536 characters).
by_cve() {
  awk '{sev[$1] = $2; pkgs[$1] = pkgs[$1] (pkgs[$1] ? ", " : "") "`" $3 "`"}
    END {for (id in sev) printf "- %s (%s): %s\n", id, sev[id], pkgs[id]}' | sort |
    awk 'NR <= 50 {print} END {if (NR > 50) printf "- … and %d more\n", NR - 50}'
}

# Prints the What/Why sections for one old -> new pair. $1: plan.sh JSON line.
describe() {
  local repository old new base tmp n fixed added
  repository=$(jq -r .repository <<<"$1")
  old=$repository:$(jq -r .old <<<"$1")
  new=$repository:$(jq -r .tag <<<"$1")
  base=$(jq -r .base <<<"$1")
  tmp=$(mktemp -d)

  echo "### What changed"
  echo
  echo "New base: \`$base\`."
  echo
  # The base layers of both images, counted on the new base. A base whose
  # layer count changed between builds compares the wrong layers.
  n=$(crane config "$base" | jq '.rootfs.diff_ids | length' 2>/dev/null)
  # a base compared with an older build of itself: every layer is a base layer.
  [[ $base == "$new" ]] && n=1000
  if [[ -n $n ]] && packages "$old" "$n" >"$tmp/old" && packages "$new" "$n" >"$tmp/new"; then
    join -a1 -a2 -e '-' -o 0,1.2,2.2 "$tmp/old" "$tmp/new" | awk '$2 != $3' >"$tmp/diff"
    if [[ -s $tmp/diff ]]; then
      echo "| Base package | Old | New |"
      echo "| --- | --- | --- |"
      awk 'NR <= 100 {printf "| `%s` | %s | %s |\n", $1, $2, $3}
        END {if (NR > 100) printf "\n… and %d more packages.\n", NR - 100}' "$tmp/diff"
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
    # By CVE id: a CVE still open on any package of the new image is not
    # fixed, also when its package was renamed.
    cut -d' ' -f1 "$tmp/cve-old" | sort -u >"$tmp/id-old"
    cut -d' ' -f1 "$tmp/cve-new" | sort -u >"$tmp/id-new"
    fixed=$(comm -23 "$tmp/id-old" "$tmp/id-new" | grep -Fwf - "$tmp/cve-old")
    added=$(comm -13 "$tmp/id-old" "$tmp/id-new" | grep -Fwf - "$tmp/cve-new")
    if [[ -n $fixed ]]; then
      echo "Fixes $(comm -23 "$tmp/id-old" "$tmp/id-new" | grep -c .) OS CVEs (Trivy, old image against new image):"
      echo
      by_cve <<<"$fixed"
    else
      echo "${NO_FIX_NOTE:-Fixes no OS finding. It keeps the image on the current base, so the next fix lands with no extra build.}"
    fi
    if [[ -n $added ]]; then
      echo
      echo "New OS CVEs in the new image:"
      echo
      by_cve <<<"$added"
    fi
    echo
    echo "Still open in the new image: $(grep -E ' (HIGH|CRITICAL) ' "$tmp/cve-new" | cut -d' ' -f1 | sort -u | grep -c .) HIGH/CRITICAL and $(grep -c . "$tmp/id-new") total OS CVEs."
  else
    echo "Could not scan the old and new images with Trivy."
  fi
  rm -rf "$tmp"
}

pairs=$(jq -sc 'unique_by([.repository, .old, .tag]) | .[]')
if [[ $(grep -c . <<<"$pairs") -le 1 ]]; then
  describe "$pairs"
else
  while read -r pair; do
    echo "## \`$(jq -r '(.repository | split("/") | last) + "`: `" + .old + " → " + .tag' <<<"$pair")\`"
    echo
    describe "$pair" | sed 's/^### /#### /'
    echo
  done <<<"$pairs"
fi
exit 0
