#!/usr/bin/env bash
set -euo pipefail

file=${*: -1}
words=("${@:1:$#-1}")

lines=()
while IFS= read -r line || [ -n "$line" ]; do
  [[ $line =~ ^#\ -+\ \>8\ -+$ ]] && break
  [[ $line == \#* ]] && continue
  lines+=("$line")
done <"$file"
subject=${lines[0]:-}

coauthor='^[Cc]o-[Aa]uthored-[Bb]y: (.+) <[0-9]+\+([A-Za-z0-9-]+)@users\.noreply\.github\.com>$'
rest=()
coauthors=()
for line in "${lines[@]}"; do
  if [[ $line =~ $coauthor ]]; then
    coauthors+=("${BASH_REMATCH[1]} ${BASH_REMATCH[2]}")
  else
    rest+=("$line")
  fi
done
message=$(printf '%s\n' "${rest[@]}")

bad=0
refuse() {
  echo "commit message: $1"
  bad=1
}

type=""
if [[ $subject =~ ^([a-z]+)\([a-z0-9][a-z0-9._/-]*\):\ (.+)$ ]]; then
  type=${BASH_REMATCH[1]}
  summary=${BASH_REMATCH[2]}
  if [[ $summary == [A-Z]* ]]; then
    refuse "the summary starts with a capital letter; write it lowercase after the prefix"
  fi
  if [[ $summary == *. ]]; then
    refuse "the subject ends with a full stop; drop it"
  fi
else
  refuse "the subject must read type(scope): summary, like fix(update): keep the lock when a fetch fails"
fi
if [ ${#subject} -gt 72 ]; then
  refuse "the subject is ${#subject} characters; keep it at most 72, under 50 by preference"
fi
if [ "${lines[1]:-}" != "" ]; then
  refuse "the second line must be blank"
fi

has_body=0
has_test=0
has_cause=0
for line in "${rest[@]:2}"; do
  case $line in
  "Test: "?*) has_test=1 ;;
  "Cause: "?*) has_cause=1 ;;
  *[![:space:]]*) has_body=1 ;;
  esac
done
if [ "$has_body" = 0 ]; then
  refuse "the body is missing; say why the change was made"
fi
if [ "$has_test" = 0 ]; then
  refuse "no Test: line; say what was run, or Test: none, and why"
fi
if [ "$type" = fix ] && [ "$has_cause" = 0 ]; then
  refuse "a fix commit needs a Cause: line saying what let the defect through"
fi

for line in "${rest[@]:2}"; do
  case $line in
  "Test: "* | "Cause: "* | *://*) continue ;;
  esac
  if [ ${#line} -gt 72 ]; then
    refuse "a body line is ${#line} characters; wrap the body at 72"
    break
  fi
done

first_person="(^|[^[:alnum:]])(I've|I'll|I'm|I (had|have|was|am|did|will|want|think|tried|found|ran))([^[:alnum:]]|$)"
if [[ $message =~ $first_person ]]; then
  refuse "speaks in the first person (${BASH_REMATCH[2]}); say what the change does and why"
fi

private_words() {
  local name file
  [ -z "${GITHUB_ACTIONS:-}" ] || return 0
  {
    uname -n
    if [ -r /etc/nix/machines ]; then
      awk '$1 !~ /^#/ && NF { print $1 }' /etc/nix/machines | sed -E 's#^[a-z+-]+://##; s#^[^@]*@##'
    fi
  } | tr '[:upper:]' '[:lower:]' | while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf '%s\n%s\n' "$name" "${name%%.*}"
    tr '.-' '\n' <<<"$name"
  done | awk 'length($0) >= 5 && /[a-z]/ && !seen[$0]++' |
    grep -vxE 'local|localhost|localdomain|nixos|linux|ubuntu|debian|server|desktop|laptop|github' || true
  file=$(git config --get std.privateWords || true)
  if [ -n "$file" ]; then
    if [ ! -r "$file" ]; then
      echo "commit message: std.privateWords names a file that cannot be read, so the private names cannot be checked" >&2
      return 1
    fi
    cat -- "$file"
  fi
}
listed=$(private_words) || exit 1
mapfile -t private <<<"$listed"

shopt -s nocasematch
narration='(^|[^[:alnum:]])(the owner|this session|last session|previous session)([^[:alnum:]]|$)'
if [[ $message =~ $narration ]]; then
  refuse "narrates the work instead of the change (${BASH_REMATCH[2]}); say what changed and why"
fi
artefact='Claude-Session:|claude\.ai/|chatgpt\.com/|[0-9]+-agent|sub-?agent|\(1M context\)'
if [[ $message =~ $artefact ]]; then
  refuse "carries a trace of the tool that wrote it: ${BASH_REMATCH[0]}"
fi
place='(^|[^[:alnum:]])on (the |a |an |my |this )?(M[0-9]+|host|machine|laptop|desktop|box|builder)([^[:alnum:]]|$)'
for line in "${rest[@]:2}"; do
  if [[ $line == "Test: "* && $line =~ $place ]]; then
    refuse "the Test: line says where it ran (on ${BASH_REMATCH[2]}${BASH_REMATCH[3]}); name what ran, not the machine"
  fi
done
for word in "${private[@]}"; do
  [ -n "$word" ] || continue
  if [[ $message =~ (^|[^[:alnum:]_-])"$word"([^[:alnum:]_-]|$) ]]; then
    refuse "names $word, a machine this computer builds on or a word in its private list; say it without the name"
  fi
done
email='[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}'
trailer='Co-Authored-By|Generated with|noreply@anthropic\.com'
if [[ $message =~ $email ]]; then
  refuse "holds an email address: ${BASH_REMATCH[0]}"
fi
if [[ $message == */home/* ]]; then
  refuse "names a path under /home; say it relative to the repo or the home folder"
fi
if [[ $message =~ $trailer ]]; then
  refuse "carries an AI trailer: ${BASH_REMATCH[0]}; a person is credited only as Co-authored-by: Name <id+login@users.noreply.github.com>"
fi
for credited in "${coauthors[@]}"; do
  if [[ $credited =~ claude|anthropic|copilot|bot ]]; then
    refuse "credits a tool or a bot as a co-author: $credited"
  fi
done
for word in "${words[@]}"; do
  if [[ $message =~ (^|[^[:alnum:]])"$word"([^[:alnum:]]|$) ]]; then
    refuse "names $word, which stays out of every commit message"
  fi
done
exit "$bad"
