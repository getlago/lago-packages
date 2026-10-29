#!/usr/bin/env nu
# Prints one JSON object per pin whose image is not on the current
# lago-packages base, with what the build needs. New tag:
# <release>-base.<digest12>, where <release> is the deployed tag: a commit,
# <prefix>-<commit> (sha-, submitter-, rev-rec-...), either with a
# .build-<id> suffix. A rerun finds the same tag. Runs in the checkout of the
# repository that holds the pins ($PINS, optional $ECR prefix). Needs crane
# (logged in to the registry), full git history, and gh for a pin with a
# `source` repository.
use lib.nu *

# The release part of a deployed tag and its short commit, or null when the
# tag is not a <commit> build.
export def parse-release [tag: string]: nothing -> any {
  let release = $tag | split row '-base.' | first
  let m = $release | parse -r '^(?:[a-z0-9-]*[a-z]-)?(?<short>[0-9a-f]{7,40})(?:\.build-[0-9a-f]+)?$'
  if ($m | is-empty) { null } else { {release: $release, short: $m.0.short} }
}

# True when the layers of $img start with all the layers of $base.
export def starts-with-layers [img: list, base: list]: nothing -> bool {
  ($img | first ($base | length)) == $base
}

def diff-ids [ref: string]: nothing -> list {
  cmd crane config --platform linux/amd64 $ref | from json | get rootfs.diff_ids
}

# File $path at $commit, from `source` $source or from this repository.
def show [commit: string, path: string, source: string]: nothing -> string {
  if $source != '' {
    cmd gh api -H 'Accept: application/vnd.github.raw' $"repos/($source)/contents/($path)?ref=($commit)"
  } else {
    cmd git show $"($commit):($path)"
  }
}

def main [] {
  cd (git-root)
  let pins_file = $env.PINS? | default ''
  if $pins_file == '' { fail 'PINS: pins file' }
  let ecr = $env.ECR? | default ''

  for pin in (open --raw $pins_file | from yaml) {
    let name = $pin.name
    let repository = $pin.repository? | default $"($ecr)/($name)"
    if ($repository | str starts-with '/') { fail $"($name): no repository and no ECR prefix" }
    let source = $pin.source? | default ''
    let value = yaml-value $pin.file $pin.path
    if $value == null or $value == '' { fail $"($name): no tag at ($pin.file) ($pin.path)" }
    # A path can point at a full image reference (repository:tag): keep the tag.
    let tag = $value | into string | split row ':' | last
    let release = parse-release $tag
    if $release == null {
      print -e $"($name): ($tag) is not a <commit> build, skip"
      continue
    }

    # A values file can point at another repository than the pin (a hand
    # pin): skip that. Any other registry error stops the run.
    let found = ^crane digest $"($repository):($tag)" | complete
    if $found.exit_code != 0 {
      if $found.stderr !~ 'MANIFEST_UNKNOWN|not found' { fail $"($name): ($found.stderr | str trim)" }
      print -e $"::warning::($name): ($repository):($tag) not found, skip"
      continue
    }
    let base_repo = $"ghcr.io/getlago/($pin.base)"
    let base = $"($base_repo)@(cmd crane digest $'($base_repo):latest' | str trim)"
    let digest = $base | split row '@sha256:' | last
    let new = $"($release.release)-base.($digest | str substring 0..<12)"
    if $tag == $new or (starts-with-layers (diff-ids $"($repository):($tag)") (diff-ids $base)) {
      print -e $"($name): ($tag) is on the current base"
      continue
    }

    # A `source` image is built from another repository: its pin carries the
    # context and Dockerfile, as there is no images/<name>/build.json.
    let commit = if $source != '' {
      cmd gh api $"repos/($source)/commits/($release.short)" -q .sha | str trim
    } else {
      cmd git rev-parse $"($release.short)^{commit}" | str trim
    }
    let cfg = if $source != '' { {} } else {
      try-cmd git show $"($commit):images/($name)/build.json" | default '{}' | from json
    }
    let dockerfile = $pin.dockerfile? | default ($cfg.dockerfile? | default $"images/($name)/Dockerfile")
    # A rebuild of a Dockerfile that ignores the base changes nothing. A
    # failed fetch stops the run: it must not look like a missing ARG.
    let content = show $commit ($dockerfile | str replace -r '^\./' '') $source
    if not ($content | lines | any {|l| $l =~ '^ARG RUNTIME_IMAGE([= ]|$)' }) {
      print -e $"($name): ($dockerfile) at ($commit | str substring 0..<7) has no ARG RUNTIME_IMAGE, skip"
      continue
    }
    let built = (^crane digest $"($repository):($new)" | complete).exit_code == 0
    print -e $"($name): ($tag) -> ($new) \(built: ($built)\)"

    $pin | merge {
      old: $tag
      tag: $new
      commit: $commit
      base: $base
      built: $built
      repository: $repository
      source: $source
      dockerfile: $dockerfile
      context: ($pin.context? | default ($cfg.context? | default $"images/($name)"))
    } | to json -r | print
  }
}
