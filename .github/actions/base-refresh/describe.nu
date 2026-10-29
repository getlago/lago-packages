#!/usr/bin/env -S nu --stdin
# Prints the "what changed and why" part of a bump PR body, in Markdown, for
# one image: plan JSON lines on stdin. Pins of one name can sit on different
# deployed tags: each old -> new pair gets its own section.
# What: the apk packages of the base layers, old image against new image.
# Why: the OS CVEs (Trivy, any severity) the new image no longer has.
# Best effort: a failed lookup prints a note, never fails the bump.
# Needs crane and trivy, logged in to the registry.
use lib.nu *

# "package version" records of an apk database (usr/lib/apk/db/installed).
export def apk-packages [db: string]: nothing -> table {
  $db
  | split row "\n\n"
  | each {|stanza|
      let fields = $stanza | lines | parse -r '^(?<k>[PV]):(?<v>.*)$'
      let p = $fields | where k == P | get -o 0.v
      let v = $fields | where k == V | get -o 0.v
      if $p != null and $v != null { {package: $p, version: $v} }
    }
  | sort-by package
}

# The packages whose version differs, old against new, with '-' for a
# package on one side only.
export def package-diff [old: table, new: table]: nothing -> table {
  $old | rename package old
  | join --outer ($new | rename package new) package
  | default '-' old
  | default '-' new
  | where {|r| $r.old != $r.new }
  | sort-by package
}

# One Markdown item per CVE, at most 50 (a PR body holds 65536 characters).
# In: {id, severity, pkg} records.
export def by-cve [findings: table]: nothing -> list<string> {
  let items = $findings
    | group-by id
    | items {|id, rows|
        let pkgs = $rows | each {|r| $"`($r.pkg)`" } | str join ', '
        $"- ($id) \(($rows | last | get severity)\): ($pkgs)"
      }
    | sort
  let more = ($items | length) - 50
  $items | first 50 | append (if $more > 0 { [$"- … and ($more) more"] } else { [] })
}

# The apk packages in the first $n layers of image $img (linux/amd64), or
# null. The database is in the base layers.
def packages [img: string, n: int]: nothing -> any {
  let manifest = try-cmd crane manifest --platform linux/amd64 $img
  if $manifest == null { return null }
  let repo = $img | str replace -r ':[^:/]*$' ''
  mut db = ''
  for layer in ($manifest | from json | get layers.digest | first $n) {
    # tar fails on the path the layer does not have, but prints the other.
    let found = ^crane blob $"($repo)@($layer)" | ^tar -xzOf - usr/lib/apk/db/installed lib/apk/db/installed | complete
    if ($found.stdout | is-not-empty) { $db = $found.stdout }
  }
  if $db == '' { null } else { apk-packages $db }
}

# {id, severity, pkg} records of the OS findings of image $img, or null.
def cves [img: string]: nothing -> any {
  let out = try-cmd trivy image --quiet --scanners vuln --pkg-types os --format json $img
  if $out == null { return null }
  $out | from json | get -o Results | default []
  | each {|r| $r.Vulnerabilities? | default [] }
  | flatten
  | each {|v| {id: $v.VulnerabilityID, severity: $v.Severity, pkg: $v.PkgName} }
  | uniq
  | sort-by id severity pkg
}

# The What/Why sections for one old -> new pair, as lines.
def describe-pair [pin: record]: nothing -> list<string> {
  let old = $"($pin.repository):($pin.old)"
  let new = $"($pin.repository):($pin.tag)"
  mut out = ['### What changed' '' $"New base: `($pin.base)`." '']

  # The base layers of both images, counted on the new base. A base whose
  # layer count changed between builds compares the wrong layers.
  let config = try-cmd crane config $pin.base
  let n = if $config == null { null } else { $config | from json | get -o rootfs.diff_ids | default [] | length }
  let old_pkgs = if $n == null { null } else { packages $old $n }
  let new_pkgs = if $old_pkgs == null { null } else { packages $new $n }
  if $new_pkgs == null {
    $out = $out | append 'Could not read the apk database of the base layers.'
  } else {
    let diff = package-diff $old_pkgs $new_pkgs
    if ($diff | is-empty) {
      $out = $out | append 'No apk package changed: the base moved for another reason (file or metadata change).'
    } else {
      $out = $out | append ['| Base package | Old | New |' '| --- | --- | --- |']
      $out = $out | append ($diff | first 100 | each {|d| $"| `($d.package)` | ($d.old) | ($d.new) |" })
      if ($diff | length) > 100 {
        $out = $out | append ['' $"… and (($diff | length) - 100) more packages."]
      }
    }
  }

  $out = $out | append ['' '### Why' '']
  let cve_old = cves $old
  let cve_new = if $cve_old == null { null } else { cves $new }
  if $cve_new == null {
    return ($out | append 'Could not scan the old and new images with Trivy.')
  }
  # By CVE id: a CVE still open on any package of the new image is not
  # fixed, also when its package was renamed.
  let id_old = $cve_old | get id | uniq
  let id_new = $cve_new | get id | uniq
  let fixed_ids = $id_old | where {|id| $id not-in $id_new }
  let added_ids = $id_new | where {|id| $id not-in $id_old }
  if ($fixed_ids | is-not-empty) {
    $out = $out | append [$"Fixes ($fixed_ids | length) OS CVEs \(Trivy, old image against new image\):" '']
    $out = $out | append (by-cve ($cve_old | where id in $fixed_ids))
  } else {
    $out = $out | append 'Fixes no OS finding. It keeps the image on the current base, so the next fix lands with no extra build.'
  }
  if ($added_ids | is-not-empty) {
    $out = $out | append ['' 'New OS CVEs in the new image:' '']
    $out = $out | append (by-cve ($cve_new | where id in $added_ids))
  }
  let high = $cve_new | where severity in [HIGH CRITICAL] | get id | uniq | length
  $out | append ['' $"Still open in the new image: ($high) HIGH/CRITICAL and ($id_new | length) total OS CVEs."]
}

# The Markdown for the plan records of one image.
export def describe-pins [pins: list]: nothing -> string {
  let pairs = $pins | uniq-by repository old tag
  if ($pairs | length) <= 1 {
    return (describe-pair $pairs.0 | str join "\n")
  }
  $pairs | each {|pair|
    [$"## `($pair.old) → ($pair.tag)`" '']
    | append (describe-pair $pair | each {|l| $l | str replace -r '^### ' '#### ' })
    | append ''
  } | flatten | str join "\n"
}

def main [] {
  print (describe-pins ($in | from json --objects))
}
