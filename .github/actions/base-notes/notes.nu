#!/usr/bin/env nu
# Writes or updates the base-notes comment on PR $PR of $GH_REPO: one describe.nu section per lago-packages base the
# PR moves.
use ../base-refresh/lib.nu *

def main [] {
  let marker = '<!-- lago-packages:base-notes -->'
  # Before the diff, so the footer never names a newer commit than the notes.
  let head = cmd gh pr view $env.PR --json headRefOid -q .headRefOid | str trim | str substring 0..<7
  let pairs = cmd gh pr diff $env.PR | cmd pairs.nu | str trim
  let id = cmd gh api $"repos/($env.GH_REPO)/issues/($env.PR)/comments" --paginate --slurp | from json | flatten
    | where {|c| $c.user.login == 'github-actions[bot]' and ($c.body | str starts-with $marker) } | get -o 0.id

  mut body = if $pairs == '' {
    if $id == null {
      print $"PR ($env.PR) moves no lago-packages base"
      return
    }
    $"($marker)\nThis PR no longer moves a lago-packages base \(($head)\)."
  } else {
    let note = 'Fixes no OS finding: the new base only updates packages.'
    let notes = with-env {NO_FIX_NOTE: $note} { $"($pairs)\n" | cmd describe.nu } | str trim -r -c "\n"
    # A registry or Trivy hiccup on a rebase must not replace complete notes.
    if $id != null and ($notes | lines | any {|l| $l starts-with 'Could not ' }) {
      print '::warning::a lookup failed; the notes of an earlier run stay'
      return
    }
    ([$marker '**What is in the new lago-packages bases**' '' $notes ''
      $"<sub>For ($head). Old image against new image: apk packages of the base layers, and OS CVEs found by Trivy.</sub>"] | str join "\n")
  }

  # GitHub refuses a comment over 65536 characters.
  if ($body | str length -g) > 60000 { $body = ($body | str substring -g 0..<60000) + "\n\n… cut at 60000 characters." }
  if $id != null {
    cmd gh api -X PATCH $"repos/($env.GH_REPO)/issues/comments/($id)" -f $"body=($body)" | ignore
  } else {
    cmd gh api $"repos/($env.GH_REPO)/issues/($env.PR)/comments" -f $"body=($body)" | ignore
  }
}
