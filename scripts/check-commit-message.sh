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
message=$(printf '%s\n' "${lines[@]}")
subject=${lines[0]:-}

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
for line in "${lines[@]:2}"; do
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

shopt -s nocasematch
email='[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}'
trailer='Co-Authored-By|Generated with|noreply@anthropic\.com'
if [[ $message =~ $email ]]; then
  refuse "holds an email address: ${BASH_REMATCH[0]}"
fi
if [[ $message == */home/* ]]; then
  refuse "names a path under /home; say it relative to the repo or the home folder"
fi
if [[ $message =~ $trailer ]]; then
  refuse "carries an AI trailer: ${BASH_REMATCH[0]}"
fi
for word in "${words[@]}"; do
  if [[ $message =~ (^|[^[:alnum:]])"$word"([^[:alnum:]]|$) ]]; then
    refuse "names $word, which stays out of every commit message"
  fi
done
exit "$bad"
