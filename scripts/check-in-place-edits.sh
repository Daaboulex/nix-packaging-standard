#!/usr/bin/env bash
set -euo pipefail

cd "$1"
listed=$(find . -name '*.nix' -type f -printf '%P\n' | LC_ALL=C sort)
[ -n "$listed" ] || exit 0
mapfile -t files <<<"$listed"

awk -v q="'" '
BEGIN {
  lead = "(^[[:space:]]*|[;&({][[:space:]]*|[|][|][[:space:]]*|[[:space:]](then|do|else|-exec|xargs|exec)[[:space:]]+|/)"
  tool = "(sed[[:space:]]+(-[[:alnum:]-]*[[:space:]]+)*(-[[:alpha:]]*i|--in-place)|perl[[:space:]]+(-[[:alnum:]]*[[:space:]]+)*-[[:alpha:]]*i|g?awk[[:space:]]+(-[[:alnum:]]*[[:space:]]+)*-i[[:space:]]*inplace|patch[[:space:]][^|]*[|][|][[:space:]]*true)"
  edit = lead tool "|--replace-quiet"
  assertion = "^[[:space:]]*((landed|gone|exactly_one|landed_soft)[[:space:]]|(if[[:space:]]+(![[:space:]]+)?)?grep[[:space:]])"
  elsewhere = "^[\"" q "]?[$/]"
}
function quotes(text) {
  gsub(/\$\{[^}]*\}/, "", text)
  gsub(q q, "", text)
  return gsub(q, "", text)
}
function continues(text, line) {
  return line ~ /\\[[:space:]]*$/ || quotes(text) % 2 == 1
}
function after(text, word, value) {
  if (!match(text, word "[[:space:]]+[^[:space:]]+")) return ""
  value = substr(text, RSTART, RLENGTH)
  sub("^" word "[[:space:]]+", "", value)
  return value
}
function target(text) {
  gsub(/\\\n|\n/, " ", text)
  if (text ~ /-exec[[:space:]]/ && after(text, "find") != "") return after(text, "find")
  if (after(text, "substituteInPlace") != "") return after(text, "substituteInPlace")
  sub(/[[:space:];]+$/, "", text)
  match(text, /[^[:space:]]+$/)
  return substr(text, RSTART, RLENGTH)
}
function edited() {
  open = 0
  run = 1
  if (target(command) !~ elsewhere) {
    sub(/^[[:space:]]+/, "", first)
    unasserted = unasserted path ":" start ": " first "\n"
  }
}
function settle(asserted) {
  if (open) edited()
  if (!asserted && unasserted != "") {
    printf "%s", unasserted
    found = 1
  }
  run = 0
  unasserted = ""
}
FNR == 1 {
  settle(0)
  path = FILENAME
}
open {
  command = command "\n" $0
  if (!continues(command, $0)) edited()
  next
}
/^[[:space:]]*(#|$)/ { next }
$0 ~ edit {
  command = $0
  first = $0
  start = FNR
  if (continues(command, $0)) open = 1
  else edited()
  next
}
run { settle($0 ~ assertion) }
END {
  settle(0)
  if (found) {
    print ""
    print "Each line above edits upstream source and reports nothing when the edit does not apply,"
    print "so a renamed upstream anchor ships the package without it. On the line after the edit,"
    print "write landed FILE TEXT LABEL, gone FILE TEXT LABEL or exactly_one FILE ERE LABEL from"
    print "inputs.std.lib.patchAssertions, or make an edit that fails by itself: substituteInPlace"
    print "--replace-fail, or patch without || true."
    exit 1
  }
}
' "${files[@]}"
