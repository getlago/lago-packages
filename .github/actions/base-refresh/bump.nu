#!/usr/bin/env -S nu --stdin
# Writes the new tags of one image (plan JSON lines on stdin) into the values
# files, then opens or updates its PR on base-refresh/<name>. The PR body says
# what changed in the base and why (describe.nu). Needs gh (GH_TOKEN with
# contents + pull-requests write), and crane and trivy logged in to the
# registry.
use lib.nu *
use describe.nu describe-pins

# $content with `<key>: [<repository>:]<old>` set to $new on its one
# matching line. Edits only that line: a YAML rewrite would reformat the
# whole file.
export def edit-tag [content: string, key: string, old: string, new: string]: nothing -> any {
  let old_re = $old | str replace -ar '([\\.+*?()|\[\]{}^$])' '\$1'
  let re = r#'^(\s*'# + $key + r#': ["']?(?:[^\s"']*:)?)'# + $old_re + r#'(["']?\s*(?:#.*)?)$'#
  let lines = $content | split row "\n"
  let hits = $lines | enumerate | where {|l| $l.item =~ $re }
  if ($hits | length) != 1 { return null }
  let i = $hits.0.index
  $lines | update $i ($lines | get $i | str replace -r $re $'${1}($new)${2}') | str join "\n"
}

def main [] {
  let pins = $in | from json --objects
  cd (git-root)

  mut body = [
    'Rebuilds the deployed commit on the newest lago-packages base. No source change.'
    "Only `RUNTIME_IMAGE` is set. The build stage uses the Dockerfile's default build image, which can be newer than the deployed build's."
    ''
  ]
  for pin in $pins {
    let key = $pin.path | split row '.' | last
    let edited = edit-tag (open --raw $pin.file) $key $pin.old $pin.tag
    if $edited == null { fail $"($pin.file): no single line for ($pin.path): ($pin.old)" }
    $edited | save -f $pin.file
    let value = yaml-value $pin.file $pin.path | into string | split row ':' | last
    if $value != $pin.tag { fail $"($pin.file): ($pin.path) is not ($pin.tag)" }
    $body = $body | append $"- `($pin.file)` `($pin.path)`: `($pin.old)` → `($pin.tag)`"
  }

  if (^git diff --quiet | complete).exit_code == 0 {
    print -e 'No tag to change.'
    return
  }
  $body = $body | append ['' (describe-pins $pins) '']
  # The run that published each new base: build-base.yaml writes it on the
  # base index. Older bases have no annotation: fall back to the run that
  # sent base-updated (TRIGGER_URL), empty on a scheduled or manual refresh.
  for base in ($pins | get base | uniq | sort) {
    let manifest = try-cmd crane manifest $base
    let annotated = if $manifest == null { null } else {
      try { $manifest | from json | get -o annotations | default {} | get -o 'dev.getlago.build-run' } catch { null }
    }
    let run_url = $annotated | default ($env.TRIGGER_URL? | default '')
    if $run_url != '' {
      $body = $body | append $"Base build \(`($base | split row '@' | first)`\): ($run_url)"
    }
  }
  if ($env.RUN_URL? | default '') != '' {
    $body = $body | append $"Refresh run: ($env.RUN_URL)"
  }
  mut text = ($body | str join "\n") + "\n"
  # GitHub refuses a PR body over 65536 characters.
  if ($text | str length) > 60000 {
    $text = ($text | str substring 0..<60000) + "\n\n… cut at 60000 characters.\n"
  }
  let body_file = mktemp -t body.XXXXXX
  $text | save -f $body_file

  let name = $pins.0.name
  let branch = $"base-refresh/($name)"
  let title = $"chore\(($name)\): rebuild on the fresh lago-packages base"
  # From main, whatever ref this run checked out. The edits carry over.
  cmd git fetch -q origin main
  cmd git checkout -B $branch origin/main
  cmd git commit -qam $title
  cmd git push --force origin $branch

  # REST, not `gh pr view/edit`: those also read the PR's requested
  # reviewers, and a fine-grained token cannot read team reviewers
  # (CODEOWNERS).
  let repo = if ($env.GITHUB_REPOSITORY? | default '') != '' { $env.GITHUB_REPOSITORY } else {
    cmd gh repo view --json nameWithOwner -q .nameWithOwner | str trim
  }
  let owner = $repo | split row '/' | first
  let pr = cmd gh api $"repos/($repo)/pulls?head=($owner):($branch)&state=open" -q '.[0].number // empty' | str trim
  if $pr != '' {
    print (cmd gh api -X PATCH $"repos/($repo)/pulls/($pr)" -F $"body=@($body_file)" -q .html_url | str trim)
  } else {
    print (cmd gh pr create --base main --head $branch --title $title --body-file $body_file | str trim)
  }
}
