#!/usr/bin/env bash
# Writes the new tags of every refreshed image into the values files, then
# opens or updates ONE PR on base-refresh/all. $1: a directory with one
# subdirectory per image, written by section.sh (pins.jsonl, section.md,
# summary.tsv). PLANNED (env, optional): the image names plan.sh listed, so
# the body can name the ones whose refresh job failed.
# Needs yq, jq and gh (GH_TOKEN with contents + pull-requests write).
set -euo pipefail
dir=$(cd "$1" && pwd)
cd "$(git rev-parse --show-toplevel)"

# Change only `<key>: [<repository>:]<old>`: yq -i would reformat the whole
# file.
apply() {
  local pin file path old new match value
  while read -r pin; do
    file=$(jq -r .file <<<"$pin")
    path=$(jq -r .path <<<"$pin")
    old=$(jq -r .old <<<"$pin")
    new=$(jq -r .tag <<<"$pin")
    match="^([[:space:]]*${path##*.}: [\"']?([^[:space:]\"']*:)?)${old//./\\.}([\"']?[[:space:]]*(#.*)?)$"
    if [[ $(grep -cE "$match" "$file") != 1 ]]; then
      echo "$file: no single line for $path: $old" >&2
      return 1
    fi
    sed -E "s|$match|\1$new\3|" "$file" >"$file.tmp" && mv "$file.tmp" "$file"
    value=$(yq "$path" "$file")
    [[ ${value##*:} == "$new" ]] || { echo "$file: $path is not $new" >&2; return 1; }
  done
}

images=()
for d in "$dir"/*/; do
  d=${d%/}
  [[ -s $d/pins.jsonl ]] || continue
  # An image whose tags no longer apply stays out; the others still ship.
  if apply <"$d/pins.jsonl"; then
    images+=("$d")
  else
    echo "skipping $(basename "$d"): its tags did not apply" >&2
    git checkout -q -- .
    for k in "${images[@]}"; do apply <"$k/pins.jsonl"; done
  fi
done

if (( ${#images[@]} == 0 )) || git diff --quiet; then
  echo "No tag to change." >&2
  exit 0
fi

body=$(mktemp)
{
  echo "Rebuilds the deployed commits on the newest lago-packages bases. No source change."
  echo "Only \`RUNTIME_IMAGE\` is set. The build stage uses the Dockerfile's default build image, which can be newer than the deployed build's."
  echo
  echo "| Image | Old → new | OS CVEs fixed |"
  echo "| --- | --- | --- |"
  for d in "${images[@]}"; do
    awk -F'\t' '{printf "| `%s` | `%s` → `%s` | %s |\n", $1, $2, $3, $4}' "$d/summary.tsv"
  done
  # Planned but not here: its build, scan or section failed. The run has it.
  if [[ -n ${PLANNED:-} ]]; then
    missing=$(comm -23 <(jq -r '.[]' <<<"$PLANNED" | sort -u) \
      <(for d in "${images[@]}"; do basename "$d"; done | sort -u))
    if [[ -n $missing ]]; then
      echo
      names=$(awk '{printf "%s`%s`", (NR > 1 ? ", " : ""), $0}' <<<"$missing")
      echo "Not in this PR (refresh failed, see the run): $names."
    fi
  fi
  echo
} >"$body"

footer=$(mktemp)
if [[ -n ${RUN_URL:-} ]]; then printf '\nRefresh run: %s\n' "$RUN_URL" >"$footer"; fi

# GitHub refuses a body over 65536 characters. The summary always stays
# whole; each image section gets an equal share of what is left.
limit=${BODY_LIMIT:-60000}
left=$(( limit - $(wc -c <"$body") - $(wc -c <"$footer") ))
share=$(( left / ${#images[@]} ))
for d in "${images[@]}"; do
  if (( $(wc -c <"$d/section.md") > share )); then
    head -c $(( share > 80 ? share - 80 : 0 )) "$d/section.md" >>"$body"
    printf '\n\n… section cut, see the refresh run.\n\n' >>"$body"
  else
    cat "$d/section.md" >>"$body"
    echo >>"$body"
  fi
done
cat "$footer" >>"$body"

if [[ -n ${DRY_RUN:-} ]]; then cat "$body"; exit 0; fi

BRANCH=base-refresh/all
TITLE="chore: rebuild on the fresh lago-packages bases"
# From main, whatever ref this run checked out. The edits carry over.
git fetch -q origin main
git checkout -B "$BRANCH" origin/main
git commit -qam "$TITLE" -m "$(for d in "${images[@]}"; do basename "$d"; done | paste -sd' ' -)"
git push --force origin "$BRANCH"

# REST, not `gh pr view/edit`: those also read the PR's requested
# reviewers, and a fine-grained token cannot read team reviewers (CODEOWNERS).
REPO=${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}
pr=$(gh api "repos/$REPO/pulls?head=${REPO%%/*}:$BRANCH&state=open" -q '.[0].number // empty')
if [[ -n $pr ]]; then
  gh api -X PATCH "repos/$REPO/pulls/$pr" -F "body=@$body" -q .html_url
else
  gh pr create --base main --head "$BRANCH" --title "$TITLE" --body-file "$body"
fi
