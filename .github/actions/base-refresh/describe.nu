#!/usr/bin/env -S nu --stdin
# Prints the "what changed and why" part of a bump PR body, in Markdown, for one image: plan JSON lines on stdin.
# Pins of one name can sit on different deployed tags: each old -> new pair gets its own section.
# What: the apk packages of the base layers, old image against new image.
# Why: the OS CVEs (Trivy, any severity) the new image no longer has.
# Best effort: a failed lookup prints a note, never fails the bump. Needs crane and trivy, logged in to the registry.
# NO_FIX_NOTE replaces the line for a new image that fixes no OS finding.
use lib.nu *

# {package, version} records of the apk database in the first $n layers of image $img (linux/amd64), or null.
# The database is in the base layers.
def packages [img: string, n: int]: nothing -> any {
  let manifest = try-cmd crane manifest --platform linux/amd64 $img
  if $manifest == null { return null }
  mut db = ''
  for layer in ($manifest | from json | get layers.digest | first $n) {
    # tar fails on the path the layer does not have, but prints the other.
    let blob = $"($img | str replace -r ':[^:/]*$' '')@($layer)"
    let found = ^crane blob $blob | ^tar -xzOf - usr/lib/apk/db/installed lib/apk/db/installed | complete
    if ($found.stdout | is-not-empty) { $db = $found.stdout }
  }
  if $db == '' { return null }
  $db | split row "\n\n" | each {|stanza|
    let f = $stanza | lines | parse -r '^(?<k>[PV]):(?<v>.*)$'
    let p = $f | where k == P | get -o 0.v
    let v = $f | where k == V | get -o 0.v
    if $p != null and $v != null { {package: $p, version: $v} }
  } | sort-by package
}

# {id, severity, pkg} records of the OS findings of image $img, or null.
def cves [img: string]: nothing -> any {
  let out = try-cmd trivy image --quiet --scanners vuln --pkg-types os --format json $img
  if $out == null { return null }
  $out | from json | get -o Results | default [] | each {|r| $r.Vulnerabilities? | default [] } | flatten
  | each {|v| {id: $v.VulnerabilityID, severity: $v.Severity, pkg: $v.PkgName} } | uniq | sort-by id severity pkg
}

# One Markdown item per CVE, at most 50 (a PR body holds 65536 characters).
def by-cve [findings: table]: nothing -> list<string> {
  let items = $findings | group-by id | items {|id, rows|
    $"- ($id) \(($rows | last | get severity)\): ($rows | each {|r| $"`($r.pkg)`" } | str join ', ')"
  } | sort
  let more = ($items | length) - 50
  $items | first 50 | append (if $more > 0 { [$"- … and ($more) more"] } else { [] })
}

# The What/Why sections for one old -> new pair, as lines.
def describe-pair [pin: record]: nothing -> list<string> {
  let old = $"($pin.repository):($pin.old)"
  let new = $"($pin.repository):($pin.tag)"
  mut out = ['### What changed' '' $"New base: `($pin.base)`." '']

  # The base layers of both images, counted on the new base. A base whose layer count changed between builds
  # compares the wrong layers.
  let config = try-cmd crane config $pin.base
  let n = if $config == null { null } else { $config | from json | get -o rootfs.diff_ids | default [] | length }
  # A base compared with an older build of itself: every layer is a base layer.
  let n = if $pin.base == $new { 1000 } else { $n }
  let old_pkgs = if $n == null { null } else { packages $old $n }
  let new_pkgs = if $old_pkgs == null { null } else { packages $new $n }
  if $new_pkgs == null {
    $out = $out | append 'Could not read the apk database of the base layers.'
  } else {
    let diff = $old_pkgs | rename package old | join --outer ($new_pkgs | rename package new) package
      | default '-' old | default '-' new | where {|r| $r.old != $r.new } | sort-by package
    if ($diff | is-empty) {
      $out = $out | append 'No apk package changed: the base moved for another reason (file or metadata change).'
    } else {
      $out = $out | append ['| Base package | Old | New |' '| --- | --- | --- |']
      $out = $out | append ($diff | first 100 | each {|d| $"| `($d.package)` | ($d.old) | ($d.new) |" })
      if ($diff | length) > 100 { $out = $out | append ['' $"… and (($diff | length) - 100) more packages."] }
    }
  }

  $out = $out | append ['' '### Why' '']
  let cve_old = cves $old
  let cve_new = if $cve_old == null { null } else { cves $new }
  if $cve_new == null { return ($out | append 'Could not scan the old and new images with Trivy.') }
  # By CVE id: a CVE still open on any package of the new image is not fixed, also when its package was renamed.
  let id_old = $cve_old | get id | uniq
  let id_new = $cve_new | get id | uniq
  let fixed_ids = $id_old | where {|id| $id not-in $id_new }
  let added_ids = $id_new | where {|id| $id not-in $id_old }
  if ($fixed_ids | is-not-empty) {
    $out = $out | append [$"Fixes ($fixed_ids | length) OS CVEs \(Trivy, old image against new image\):" '']
    $out = $out | append (by-cve ($cve_old | where id in $fixed_ids))
  } else {
    $out = $out | append (if ($env.NO_FIX_NOTE? | default '') != '' { $env.NO_FIX_NOTE } else {
      'Fixes no OS finding. It keeps the image on the current base, so the next fix lands with no extra build.'
    })
  }
  if ($added_ids | is-not-empty) {
    $out = $out | append ['' 'New OS CVEs in the new image:' ''] | append (by-cve ($cve_new | where id in $added_ids))
  }
  let high = $cve_new | where severity in [HIGH CRITICAL] | get id | uniq | length
  $out | append ['' $"Still open in the new image: ($high) HIGH/CRITICAL and ($id_new | length) total OS CVEs."]
}

# The Markdown for the plan records of one image.
export def describe-pins [pins: list]: nothing -> string {
  let pairs = $pins | uniq-by repository old tag | sort-by repository old tag
  if ($pairs | length) <= 1 { return (describe-pair $pairs.0 | str join "\n") }
  $pairs | each {|pair|
    let body = describe-pair $pair | each {|l| $l | str replace -r '^### ' '#### ' }
    [$"## `($pair.repository | split row '/' | last)`: `($pair.old) → ($pair.tag)`" ''] | append $body | append ''
  } | flatten | str join "\n"
}

def main [] {
  print (describe-pins ($in | from json --objects))
}
