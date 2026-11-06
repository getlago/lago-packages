#!/usr/bin/env bash
# Decides whether a rebuild of one image is worth a bump PR: plan.sh JSON lines
# on stdin. Prints one reason line, then exits 0 (open the PR) or 10 (skip).
# Open when the new image fixes at least one OS finding at MIN_SEVERITY or
# above (Trivy, old image against new image), when FORCE is true, or when a
# lookup fails: a scanner outage must not hold back a fix.
# Needs jq, crane and trivy, logged in to the registry.
set -uo pipefail
export LC_ALL=C
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

MIN_SEVERITY=${MIN_SEVERITY:-LOW}
rank() {
  case $1 in CRITICAL) echo 4 ;; HIGH) echo 3 ;; MEDIUM) echo 2 ;; LOW) echo 1 ;; *) echo 0 ;; esac
}
min=$(rank "$MIN_SEVERITY")
(( min > 0 )) || { echo "open: unknown MIN_SEVERITY '$MIN_SEVERITY'"; exit 0; }

if [[ ${FORCE:-false} == true ]]; then
  echo "open: forced"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fixed=0
while read -r pair; do
  repository=$(jq -r .repository <<<"$pair")
  old=$repository:$(jq -r .old <<<"$pair")
  new=$repository:$(jq -r .tag <<<"$pair")
  # No old image (first refresh of a pin) or no scan: open, and say why.
  cves "$old" >"$tmp/old" </dev/null || { echo "open: cannot scan $old"; exit 0; }
  cves "$new" >"$tmp/new" </dev/null || { echo "open: cannot scan $new"; exit 0; }
  # By CVE id, as describe.sh does: a CVE still open on any package is not fixed.
  cut -d' ' -f1 "$tmp/new" | sort -u >"$tmp/id-new"
  n=$(awk -v min="$min" -v ids="$tmp/id-new" '
    BEGIN {while ((getline id < ids) > 0) open[id] = 1
      r["CRITICAL"] = 4; r["HIGH"] = 3; r["MEDIUM"] = 2; r["LOW"] = 1}
    !($1 in open) && r[$2] >= min {seen[$1] = 1}
    END {print length(seen)}' "$tmp/old")
  fixed=$((fixed + n))
done < <(jq -sc 'unique_by([.repository, .old, .tag]) | .[]')

if (( fixed > 0 )); then
  echo "open: fixes $fixed OS finding(s) at $MIN_SEVERITY or above"
  exit 0
fi
echo "skip: no fixed OS finding at $MIN_SEVERITY or above"
exit 10
