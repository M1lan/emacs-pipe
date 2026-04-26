#!/usr/bin/env bash
project_root() {
  local d
  d=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
  printf '%s' "$d"
}

setup_epipe_env() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/epipe-bats.XXXXXX")
  export TEST_TMPDIR
  export EPIPE_RECORD_FILE="$TEST_TMPDIR/record.txt"
  : >"$EPIPE_RECORD_FILE"
  ROOT="$(project_root)"
  export ROOT
  export FAKE_EMACSCLIENT="$ROOT/tests/fixtures/fake-emacsclient.bash"
  chmod +x "$FAKE_EMACSCLIENT"
  export EMACSCLIENT="$FAKE_EMACSCLIENT"
  export TMPDIR="$TEST_TMPDIR"
  export EPIPE_BIN="${EPIPE_BIN:-$ROOT/bash/epipe.bash}"
  unset EPIPE_DEBUG EPIPE_BUFFER EPIPE_MODE
}

teardown_epipe_env() {
  if [[ -n "${TEST_TMPDIR-}" && -d "$TEST_TMPDIR" ]]; then
    rm -rf -- "$TEST_TMPDIR"
  fi
}

last_invocation() {
  awk '
    BEGIN { found=0; cur="" }
    /^invocation$/ { cur=""; found=0; next }
    /^---$/ { if (cur!="") { last=cur; found=1 } cur=""; next }
    { cur = cur $0 "\n" }
    END { if (found) printf "%s", last }
  ' "$EPIPE_RECORD_FILE"
}

invocation_count() {
  grep -c '^---$' "$EPIPE_RECORD_FILE" 2>/dev/null || echo 0
}

last_args() {
  last_invocation | awk -F= '/^arg=/ { sub(/^arg=/,""); print }'
}

last_argc() {
  last_invocation | awk -F= '/^argc=/ { print $2; exit }'
}

last_stdin() {
  last_invocation | awk '
    BEGIN { in_stdin=0 }
    /^stdin=/ { sub(/^stdin=/,""); print; in_stdin=1; next }
    in_stdin { print }
  '
}

wait_for_invocation() {
  local timeout=${1:-2}
  local start
  start=$(date +%s)
  while (( $(invocation_count) == 0 )); do
    sleep 0.05
    if (( $(date +%s) - start > timeout )); then
      return 1
    fi
  done
}
