#!/usr/bin/env bash
# Writes the new tags of one image (plan.sh JSON lines on stdin) into the
# values files, then opens or updates its PR on base-refresh/<name>.
# Needs yq, jq, gh (GH_TOKEN with contents + pull-requests write).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

body=$(mktemp)
cat >"$body" <<'MD'
Rebuilds the deployed commit on the newest lago-packages base. No source change.
Only `RUNTIME_IMAGE` is set. The build stage uses the Dockerfile's default build image, which can be newer than the deployed build's.

MD

while read -r pin; do
  name=$(jq -r .name <<<"$pin")
  file=$(jq -r .file <<<"$pin")
  path=$(jq -r .path <<<"$pin")
  old=$(jq -r .old <<<"$pin")
  new=$(jq -r .tag <<<"$pin")
  # Change only `<key>: [<repository>:]<old>`: yq -i would reformat the whole
  # file.
  match="^([[:space:]]*${path##*.}: [\"']?([^[:space:]\"']*:)?)${old//./\\.}([\"']?[[:space:]]*(#.*)?)$"
  if [[ $(grep -cE "$match" "$file") != 1 ]]; then
    echo "$file: no single line for $path: $old" >&2
    exit 1
  fi
  sed -E "s|$match|\1$new\3|" "$file" >"$file.tmp" && mv "$file.tmp" "$file"
  value=$(yq "$path" "$file")
  [[ ${value##*:} == "$new" ]] || { echo "$file: $path is not $new" >&2; exit 1; }
  echo "- \`$file\` \`$path\`: \`$old\` → \`$new\`" >>"$body"
done

if git diff --quiet; then
  echo "No tag to change." >&2
  exit 0
fi
[[ -n ${RUN_URL:-} ]] && printf '\nRun: %s\n' "$RUN_URL" >>"$body"

BRANCH=base-refresh/$name
TITLE="chore($name): rebuild on the fresh lago-packages base"
# From main, whatever ref this run checked out. The edits carry over.
git fetch -q origin main
git checkout -B "$BRANCH" origin/main
git commit -qam "$TITLE"
git push --force origin "$BRANCH"

if [[ $(gh pr view "$BRANCH" --json state -q .state 2>/dev/null) == OPEN ]]; then
  gh pr edit "$BRANCH" --body-file "$body"
else
  gh pr create --base main --head "$BRANCH" --title "$TITLE" --body-file "$body"
fi
