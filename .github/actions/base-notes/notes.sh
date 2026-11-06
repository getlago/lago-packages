#!/usr/bin/env bash
# Writes or updates the base-notes comment on PR $PR of $GH_REPO: one
# describe.sh section per lago-packages base the PR moves.
set -euo pipefail

marker='<!-- lago-packages:base-notes -->'
# before the diff, so the footer never names a newer commit than the notes.
head=$(gh pr view "$PR" --json headRefOid -q .headRefOid)
pairs=$(gh pr diff "$PR" | pairs.sh)
id=$(gh api "repos/$GH_REPO/issues/$PR/comments" --paginate --slurp |
  jq -r --arg marker "$marker" \
    'add // [] | map(select(.user.login == "github-actions[bot]" and (.body | startswith($marker)))) | first | .id // empty')

if [[ -z $pairs ]]; then
  if [[ -z $id ]]; then
    echo "PR $PR moves no lago-packages base"
    exit 0
  fi
  body="$marker
This PR no longer moves a lago-packages base (${head:0:7})."
else
  notes=$(NO_FIX_NOTE="Fixes no OS finding: the new base only updates packages." describe.sh <<<"$pairs")
  # a registry or Trivy hiccup on a rebase must not replace complete notes.
  if [[ -n $id ]] && grep -q '^Could not ' <<<"$notes"; then
    echo "::warning::a lookup failed; the notes of an earlier run stay"
    exit 0
  fi
  body="$marker
**What is in the new lago-packages bases**

$notes

<sub>For ${head:0:7}. Old image against new image: apk packages of the base layers, and OS CVEs found by Trivy.</sub>"
fi

# GitHub refuses a comment over 65536 characters.
if (( ${#body} > 60000 )); then
  body="${body:0:60000}

… cut at 60000 characters."
fi

if [[ -n $id ]]; then
  gh api -X PATCH "repos/$GH_REPO/issues/comments/$id" -f body="$body" >/dev/null
else
  gh api "repos/$GH_REPO/issues/$PR/comments" -f body="$body" >/dev/null
fi
