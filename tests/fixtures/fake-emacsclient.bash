#!/usr/bin/env bash
set -euo pipefail
record="${EPIPE_RECORD_FILE:-/dev/null}"
{
  printf '%s\n' 'invocation'
  printf 'argc=%d\n' "$#"
  for arg in "$@"; do
    printf 'arg=%s\n' "$arg"
  done
  printf 'cwd=%s\n' "$PWD"
  if [[ ! -t 0 ]]; then
    printf 'stdin='
    cat
    printf '%s\n' ''
  fi
  printf '%s\n' '---'
} >>"$record"
exit "${EPIPE_FAKE_EXIT:-0}"
