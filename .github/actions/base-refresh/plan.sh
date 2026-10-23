#!/usr/bin/env bash
# Prints one JSON object per pin whose image is not on the current
# lago-packages base, with what the build needs. New tag:
# <release>-base.<digest12>, where <release> is the deployed tag: a commit,
# <prefix>-<commit> (sha-, submitter-, rev-rec-...), either with a
# .build-<id> suffix. A rerun finds the same tag. Runs in the checkout of the repository
# that holds the pins. Needs yq, jq, crane (logged in to the registry), full
# git history, and gh for a pin with a `source` repository.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
PINS=${PINS:?pins file}

diff_ids() { crane config --platform linux/amd64 "$1" | jq -c '.rootfs.diff_ids'; }

# True when $1 starts with all the layers of $2. A registry error stops the run.
on_base() {
  local img base
  img=$(diff_ids "$1") && base=$(diff_ids "$2") || exit 1
  jq -en --argjson img "$img" --argjson base "$base" '$img[:($base | length)] == $base' >/dev/null
}

# Prints file $2 at commit $1, from `source` $3 or from this repository.
show() {
  if [[ -n $3 ]]; then gh api -H 'Accept: application/vnd.github.raw' "repos/$3/contents/$2?ref=$1"
  else git show "$1:$2"; fi
}

yq -o json -I0 '.[]' "$PINS" | while read -r pin; do
  name=$(jq -r .name <<<"$pin")
  repository=$(jq -r --arg ecr "${ECR:-}" '.repository // "\($ecr)/\(.name)"' <<<"$pin")
  [[ $repository == /* ]] && { echo "$name: no repository and no ECR prefix" >&2; exit 1; }
  source=$(jq -r '.source // ""' <<<"$pin")
  tag=$(yq "$(jq -r .path <<<"$pin")" "$(jq -r .file <<<"$pin")")
  [[ -n $tag && $tag != null ]] || { echo "$name: no tag at $(jq -r '.file + " " + .path' <<<"$pin")" >&2; exit 1; }
  # A path can point at a full image reference (repository:tag): keep the tag.
  tag=${tag##*:}
  release=${tag%%-base.*}
  if [[ ! $release =~ ^([a-z0-9-]*[a-z]-)?([0-9a-f]{7,40})(\.build-[0-9a-f]+)?$ ]]; then
    echo "$name: $tag is not a <commit> build, skip" >&2
    continue
  fi
  short=${BASH_REMATCH[2]}

  # A values file can point at another repository than the pin (a hand pin):
  # skip that. Any other registry error stops the run.
  if ! err=$(crane digest "$repository:$tag" 2>&1 >/dev/null); then
    [[ $err == *MANIFEST_UNKNOWN* || $err == *"not found"* ]] || { echo "$name: $err" >&2; exit 1; }
    echo "::warning::$name: $repository:$tag not found, skip" >&2
    continue
  fi
  base=ghcr.io/getlago/$(jq -r .base <<<"$pin")
  base=$base@$(crane digest "$base:latest")
  digest=${base#*@sha256:}
  new=$release-base.${digest:0:12}
  if [[ $tag == "$new" ]] || on_base "$repository:$tag" "$base"; then
    echo "$name: $tag is on the current base" >&2
    continue
  fi

  # A `source` image is built from another repository: its pin carries the
  # context and Dockerfile, as there is no images/<name>/build.json.
  if [[ -n $source ]]; then
    commit=$(gh api "repos/$source/commits/$short" -q .sha)
    cfg='{}'
  else
    commit=$(git rev-parse "$short^{commit}")
    cfg=$(git show "$commit:images/$name/build.json" 2>/dev/null || echo '{}')
  fi
  dockerfile=$(jq -r --argjson cfg "$cfg" '.dockerfile // $cfg.dockerfile // "images/\(.name)/Dockerfile"' <<<"$pin")
  # A rebuild of a Dockerfile that ignores the base changes nothing. A failed
  # fetch stops the run: it must not look like a missing ARG.
  content=$(show "$commit" "${dockerfile#./}" "$source")
  if ! grep -qE '^ARG RUNTIME_IMAGE([= ]|$)' <<<"$content"; then
    echo "$name: $dockerfile at ${commit:0:7} has no ARG RUNTIME_IMAGE, skip" >&2
    continue
  fi
  built=false
  crane digest "$repository:$new" >/dev/null 2>&1 && built=true
  echo "$name: $tag -> $new (built: $built)" >&2

  jq -nc --argjson pin "$pin" --argjson cfg "$cfg" --arg old "$tag" --arg tag "$new" \
    --arg commit "$commit" --arg base "$base" --argjson built "$built" \
    --arg repository "$repository" --arg source "$source" --arg dockerfile "$dockerfile" \
    '$pin + {old: $old, tag: $tag, commit: $commit, base: $base, built: $built,
      repository: $repository, source: $source, dockerfile: $dockerfile,
      context: ($pin.context // $cfg.context // "images/\($pin.name)")}'
done
