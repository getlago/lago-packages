#!/usr/bin/env -S nu --stdin
# Prints one describe.nu JSON line per lago-packages base that a PR moves: a unified diff on stdin. Within each hunk,
# the k-th removed ref of a base pairs with its k-th added ref, as an in-place edit lists them, so two Dockerfiles
# moved to different tags never pair across.

# Refs end at the digest, a quote, a space or the line end: an -aarch64 tag is another image.
const REF = '(?<repository>ghcr\.io/getlago/[a-z0-9._-]+):(?<tag>[0-9]{8}-r[0-9]+)(?:[@ \t"\x27]|$)'

def pairs [hunk: list]: nothing -> list<string> {
  $hunk | group-by repository | items {|repository, refs|
    ($refs | where sign == '-' | get tag) | zip ($refs | where sign == '+' | get tag)
    | where {|p| $p.0 != $p.1 } | each {|p| $"($repository) ($p.0) ($p.1)" }
  } | flatten
}

def main [] {
  mut hunk = []
  mut out = []
  for line in ($in | lines) {
    if $line =~ '^(--- |\+\+\+ |@@|diff )' {
      $out = $out ++ (pairs $hunk)
      $hunk = []
    } else if $line =~ '^[-+]' {
      $hunk = $hunk ++ ($line | str substring 1.. | parse -r $REF | insert sign ($line | str substring 0..<1))
    }
  }
  for p in ($out ++ (pairs $hunk) | uniq | sort | each { split row ' ' }) {
    print ({repository: $p.0, old: $p.1, tag: $p.2, base: $"($p.0):($p.2)"} | to json -r)
  }
}
