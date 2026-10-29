#!/usr/bin/env nu
# Starts the base-rebuild.yaml of the pin's `builder` repository for one plan
# object ($PIN), then waits for that run. The builder rebuilds with its own
# secrets and registry access. Its run-name must be
# "base rebuild <tag> <nonce>", so this script finds the run. Needs gh
# (GH_TOKEN with actions write on the builder). `builder-ref` picks the
# branch, for a test.
use lib.nu *

def main [] {
  let pin = $env.PIN | from json
  let builder = $pin.builder
  let tag = $pin.tag
  let nonce = $"($env.NONCE? | default ($nu.pid | into string))-($pin.name)-(random int 0..32767)"
  let ref = $pin.builder-ref? | default ''
  let title = $"base rebuild ($tag) ($nonce)"

  let ref_args = if $ref != '' { [--ref $ref] } else { [] }
  cmd gh workflow run base-rebuild.yaml -R $builder ...$ref_args -f $"commit=($pin.commit)" -f $"base=($pin.base)" -f $"tag=($tag)" -f $"name=($pin.name)" -f $"nonce=($nonce)"

  # The dispatch API gives no run id: find the run by its exact name.
  mut id = ''
  for _ in 1..30 {
    let runs = try-cmd gh run list -R $builder -w base-rebuild.yaml -e workflow_dispatch -L 30 --json databaseId,displayTitle
    let match = $runs | default '[]' | from json | where displayTitle == $title
    if ($match | is-not-empty) {
      $id = $match.0.databaseId | into string
      break
    }
    sleep 10sec
  }
  if $id == '' { fail $"($builder): no run named \"($title)\"" }
  print -e $"($pin.name): https://github.com/($builder)/actions/runs/($id)"

  # gh run watch stops on any API error: watch again until the run completes.
  loop {
    let state = try-cmd gh run view $id -R $builder --json status,conclusion
    if $state != null {
      let state = $state | from json
      if $state.status == 'completed' {
        if $state.conclusion != 'success' { fail $"($pin.name): rebuild completed ($state.conclusion)" }
        break
      }
    }
    if (^gh run watch $id -R $builder --interval 30 | complete).exit_code != 0 { sleep 30sec }
  }
}
