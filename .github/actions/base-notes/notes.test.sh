#!/usr/bin/env bash
# Tests notes.sh against a fake gh and a fake describe.sh: no GitHub, no registry.
# Run: .github/actions/base-notes/notes.test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

# fake gh: serves $work/diff and $work/comments.json, logs each write to $work/calls.
cat >"$work/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") echo 0123456789abcdef ;;
  "pr diff") cat "$WORK/diff" ;;
  "api repos/o/r/issues/7/comments")
    if [[ $3 == --paginate ]]; then cat "$WORK/comments.json"; else echo "POST" >>"$WORK/calls"; fi ;;
  "api -X") echo "PATCH $4" >>"$WORK/calls" ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
SH
# fake describe.sh: prints $WORK/notes.
cat >"$work/describe.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
cat "$WORK/notes"
SH
chmod +x "$work/gh" "$work/describe.sh"

moved='-FROM ghcr.io/getlago/a-base:20261103-r1@sha256:aaa
+FROM ghcr.io/getlago/a-base:20261104-r2@sha256:bbb'
bot='[[{"id": 1, "user": {"login": "someone"}, "body": "<!-- lago-packages:base-notes --> fake"},
       {"id": 42, "user": {"login": "github-actions[bot]"}, "body": "<!-- lago-packages:base-notes -->\nold"}]]'

run() {
  local name=$1 diff=$2 comments=$3 notes=$4 want=$5 got
  printf '%s\n' "$diff" >"$work/diff"
  printf '%s\n' "$comments" >"$work/comments.json"
  printf '%s\n' "$notes" >"$work/notes"
  : >"$work/calls"
  WORK=$work PATH="$work:$here:$PATH" GH_REPO=o/r PR=7 "$here/notes.sh" >/dev/null
  got=$(cat "$work/calls")
  if [[ $got == "$want" ]]; then echo "ok   $name"; else
    echo "FAIL $name"; echo "  want: $want"; echo "  got:  $got"; fail=1
  fi
}

run "first run posts a comment" "$moved" '[[]]' "### What changed" "POST"
run "a later run updates the bot comment, not a look-alike" "$moved" "$bot" "### What changed" "PATCH repos/o/r/issues/comments/42"
run "a failed lookup keeps the earlier notes" "$moved" "$bot" "Could not scan the old and new images with Trivy." ""
run "a failed lookup still posts on the first run" "$moved" '[[]]' "Could not scan the old and new images with Trivy." "POST"
run "no base moved and no comment: nothing to do" " context" '[[]]' "" ""
run "no base moved any more: the comment says so" " context" "$bot" "" "PATCH repos/o/r/issues/comments/42"

exit $fail
