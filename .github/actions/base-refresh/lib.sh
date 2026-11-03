#!/usr/bin/env bash
# Image lookups shared by describe.sh and gate.sh. Sourced, not run.
# Needs jq, crane and trivy, logged in to the registry.

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
