#!/usr/bin/env bash
# Starts the base-rebuild.yaml of the pin's `builder` repository for one
# plan.sh object ($PIN), then waits for that run. The builder rebuilds with
# its own secrets and registry access. Its run-name must be
# "base rebuild <tag> <nonce>", so this script finds the run. Needs gh
# (GH_TOKEN with actions write on the builder) and jq. `builder-ref` picks
# the branch, for a test.
set -euo pipefail
field() { jq -r ".$1 // \"\"" <<<"$PIN"; }
builder=$(field builder)
tag=$(field tag)
nonce="${NONCE:-$$}-$(field name)-$RANDOM"
ref=$(field '"builder-ref"')

gh workflow run base-rebuild.yaml -R "$builder" ${ref:+--ref "$ref"} \
  -f commit="$(field commit)" -f base="$(field base)" -f tag="$tag" \
  -f name="$(field name)" -f nonce="$nonce"

# The dispatch API gives no run id: find the run by its exact name.
run=
for _ in $(seq 30); do
  run=$(gh run list -R "$builder" -w base-rebuild.yaml -e workflow_dispatch -L 30 \
    --json databaseId,displayTitle \
    -q "[.[] | select(.displayTitle == \"base rebuild $tag $nonce\")][0].databaseId // empty")
  [[ -n $run ]] && break
  sleep 10
done
[[ -n $run ]] || { echo "$builder: no run named \"base rebuild $tag $nonce\"" >&2; exit 1; }
echo "$(field name): https://github.com/$builder/actions/runs/$run" >&2

# gh run watch stops on any API error: watch again until the run completes.
until state=$(gh run view "$run" -R "$builder" --json status,conclusion -q '.status + " " + .conclusion' 2>/dev/null) &&
  [[ $state == completed* ]]; do
  gh run watch "$run" -R "$builder" --interval 30 >/dev/null 2>&1 || sleep 30
done
[[ $state == "completed success" ]] || { echo "$(field name): rebuild $state" >&2; exit 1; }
