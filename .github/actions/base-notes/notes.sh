#!/usr/bin/env bash
# Writes or updates the base-notes comment on PR $PR of $GH_REPO: one
# describe.sh section per lago-packages base the PR moves.
set -euo pipefail

marker='<!-- lago-packages:base-notes -->'
pairs=$(gh pr diff "$PR" | pairs.sh)
if [[ -z $pairs ]]; then
  echo "PR $PR moves no lago-packages base"
  exit 0
fi

head=$(gh pr view "$PR" --json headRefOid -q .headRefOid)
body=$(
  echo "$marker"
  echo "## What is in the new lago-packages bases"
  echo
  describe.sh <<<"$pairs"
  echo
  echo "<sub>For ${head:0:7}. Old image against new image: apk packages of the base layers, and OS CVEs found by Trivy.</sub>"
)

# the bot's own earlier comment, so a rebase updates it instead of adding one.
id=$(gh api "repos/$GH_REPO/issues/$PR/comments" --paginate \
  -q ".[] | select(.user.login == \"github-actions[bot]\" and (.body | startswith(\"$marker\"))) | .id" | head -n 1)
if [[ -n $id ]]; then
  gh api -X PATCH "repos/$GH_REPO/issues/comments/$id" -f body="$body" >/dev/null
else
  gh api "repos/$GH_REPO/issues/$PR/comments" -f body="$body" >/dev/null
fi
