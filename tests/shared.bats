#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load 'fixtures/helpers'

setup() { setup_epipe_env; }
teardown() { teardown_epipe_env; }

run_epipe() { run "$EPIPE_BIN" "$@"; }
run_epipe_with_input() {
    local input=$1; shift
    run bash -c "printf '%s' \"\$1\" | \"\$2\" \"\${@:3}\"" _ "$input" "$EPIPE_BIN" "$@"
}

@test "version flag prints prog and version" {
    run "$EPIPE_BIN" --version
    [ "$status" -eq 0 ]
    [[ "$output" == "epipe "* ]]
}

@test "short version flag works" {
    run "$EPIPE_BIN" -V
    [ "$status" -eq 0 ]
    [[ "$output" == "epipe "* ]]
}

@test "help output contains key sections" {
    run "$EPIPE_BIN" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"USAGE:"* ]]
    [[ "$output" == *"EMACS MODE:"* ]]
    [[ "$output" == *"WAIT:"* ]]
    [[ "$output" == *"TEMPFILE:"* ]]
    [[ "$output" == *"VERBOSITY:"* ]]
    [[ "$output" == *"EXIT CODES:"* ]]
}

@test "short help flag works" {
    run "$EPIPE_BIN" -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"USAGE:"* ]]
}

@test "unknown long option exits 2" {
    run "$EPIPE_BIN" --bogus
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown option: --bogus"* ]]
}

@test "unknown short option exits 2" {
    run "$EPIPE_BIN" -Q
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown"* ]]
}

@test "invalid mode value exits 2" {
    run "$EPIPE_BIN" --mode=garbage
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid mode"* ]]
}

@test "tty stdin refuses with exit 2" {
    run -2 "$EPIPE_BIN"
    [ "$status" -eq 2 ]
    [[ "$output" == *"stdin must be a pipe"* ]]
}

@test "default mode is file, no --eval, passes path positionally" {
    run_epipe_with_input "hello" --wait
    [ "$status" -eq 0 ]
    args=$(last_args)
    [[ "$args" != *"--eval"* ]]
    [[ "$args" != *"--no-wait"* ]]
    last_arg=$(last_args | tail -1)
    [[ "$last_arg" == *"epipe-"* ]]
}

@test "default async mode passes --no-wait to emacsclient" {
    run_epipe_with_input "hello"
    [ "$status" -eq 0 ]
    sleep 0.1
    args=$(last_args)
    [[ "$args" == *"--no-wait"* ]]
}

@test "--wait does NOT pass --no-wait" {
    run_epipe_with_input "hello" --wait
    [ "$status" -eq 0 ]
    args=$(last_args)
    [[ "$args" != *"--no-wait"* ]]
}

@test "--sync alias for --wait" {
    run_epipe_with_input "hello" --sync
    [ "$status" -eq 0 ]
    args=$(last_args)
    [[ "$args" != *"--no-wait"* ]]
}

@test "-w short option for --wait" {
    run_epipe_with_input "hello" -w
    [ "$status" -eq 0 ]
    args=$(last_args)
    [[ "$args" != *"--no-wait"* ]]
}

@test "--mode=eval uses --eval with insert-file-contents" {
    run_epipe_with_input "hello" --wait --mode=eval
    [ "$status" -eq 0 ]
    args=$(last_args)
    [[ "$args" == *"--eval"* ]]
    [[ "$args" == *"insert-file-contents"* ]]
    [[ "$args" == *"*pipe*"* ]]
}

@test "--mode=inline uses --eval with insert literal" {
    run_epipe_with_input "hello world" --wait --mode=inline
    [ "$status" -eq 0 ]
    args=$(last_args)
    [[ "$args" == *"--eval"* ]]
    [[ "$args" == *"(insert "* ]]
    [[ "$args" == *"hello world"* ]]
    [[ "$args" != *"insert-file-contents"* ]]
}

@test "--mode=eval includes delete-file by default" {
    run_epipe_with_input "hello" --wait --mode=eval
    args=$(last_args)
    [[ "$args" == *"delete-file"* ]]
}

@test "--mode=eval --keep does NOT include delete-file" {
    run_epipe_with_input "hello" --wait --mode=eval --keep
    args=$(last_args)
    [[ "$args" != *"delete-file"* ]]
}

@test "-m short for --mode" {
    run_epipe_with_input "hi" --wait -m eval
    args=$(last_args)
    [[ "$args" == *"insert-file-contents"* ]]
}

@test "--buffer changes buffer name in eval mode" {
    run_epipe_with_input "x" --wait --mode=eval --buffer "*scratch-pipe*"
    args=$(last_args)
    [[ "$args" == *"*scratch-pipe*"* ]]
}

@test "-b short for --buffer" {
    run_epipe_with_input "x" --wait --mode=eval -b "*xyz*"
    args=$(last_args)
    [[ "$args" == *"*xyz*"* ]]
}

@test "extra elisp after -- is appended" {
    run_epipe_with_input "x" --wait --mode=eval -- '(message "hi")'
    args=$(last_args)
    [[ "$args" == *"(message"* ]]
    [[ "$args" == *"hi"* ]]
}

@test "elisp escaping handles double quote in buffer name" {
    run_epipe_with_input "x" --wait --mode=eval --buffer 'a"b'
    args=$(last_args)
    [[ "$args" == *'\"b'* ]]
}

@test "elisp escaping handles backslash in buffer name" {
    run_epipe_with_input "x" --wait --mode=eval --buffer 'a\b'
    args=$(last_args)
    [[ "$args" == *'\\b'* ]]
}

@test "inline mode escapes newlines as \\n" {
    run_epipe_with_input $'one\ntwo' --wait --mode=inline
    args=$(last_args)
    [[ "$args" == *'one\ntwo'* ]]
}

@test "--keep keeps the temp file in file mode" {
    pre=$(ls "$TEST_TMPDIR" | wc -l)
    run_epipe_with_input "stay" --wait --keep
    [ "$status" -eq 0 ]
    found=$(ls "$TEST_TMPDIR"/epipe-* 2>/dev/null | wc -l)
    [ "$found" -ge 1 ]
}

@test "default file mode async leaves file (because emacs may still need it)" {
    run_epipe_with_input "async" --no-wait
    [ "$status" -eq 0 ]
    sleep 0.1
    found=$(ls "$TEST_TMPDIR"/epipe-* 2>/dev/null | wc -l)
    [ "$found" -ge 1 ]
}

@test "wait + no keep deletes file in file mode after emacsclient returns" {
    run_epipe_with_input "gone" --wait
    [ "$status" -eq 0 ]
    found=$(ls "$TEST_TMPDIR"/epipe-1* "$TEST_TMPDIR"/epipe-stage* 2>/dev/null | wc -l | tr -d ' ')
    [ "$found" = "0" ]
}

@test "--tee echoes input to stdout" {
    run_epipe_with_input "tee-me" --wait --tee
    [ "$status" -eq 0 ]
    [[ "$output" == *"tee-me"* ]]
}

@test "-t short for --tee" {
    run_epipe_with_input "abc" --wait -t
    [[ "$output" == *"abc"* ]]
}

@test "-v emits info to stderr in wait mode" {
    run_epipe_with_input "x" --wait -v
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"epipe:"* ]] || [[ "$output" == *"epipe:"* ]]
}

@test "--debug emits logfmt to stderr" {
    run_epipe_with_input "x" --wait --debug
    [ "$status" -eq 0 ]
    out="${stderr:-$output}"
    [[ "$out" == *"level=info"* ]]
    [[ "$out" == *"event=start"* ]]
    [[ "$out" == *"component=epipe"* ]]
}

@test "EPIPE_DEBUG=1 forces debug" {
    EPIPE_DEBUG=1 run_epipe_with_input "x" --wait
    out="${stderr:-$output}"
    [[ "$out" == *"event=start"* ]]
}

@test "EPIPE_BUFFER sets default buffer name" {
    EPIPE_BUFFER="*custom*" run_epipe_with_input "x" --wait --mode=eval
    args=$(last_args)
    [[ "$args" == *"*custom*"* ]]
}

@test "EPIPE_MODE sets default mode" {
    EPIPE_MODE=eval run_epipe_with_input "x" --wait
    args=$(last_args)
    [[ "$args" == *"insert-file-contents"* ]]
}

@test "--pattern uses {hash} template" {
    run_epipe_with_input "fixed" --wait --keep --pattern "epipe-test-{hash}"
    found=$(ls "$TEST_TMPDIR" 2>/dev/null | grep '^epipe-test-' | head -1)
    [ -n "$found" ]
}

@test "--tmpdir places file in custom dir" {
    custom="$TEST_TMPDIR/sub"
    mkdir -p "$custom"
    run_epipe_with_input "in-sub" --wait --tmpdir "$custom"
    [ "$status" -eq 0 ]
    args=$(last_args)
    [[ "$args" == *"$custom"* ]]
}

@test "missing emacsclient exits 127" {
    EMACSCLIENT="/no/such/binary/anywhere" run -127 bash -c "printf '%s' \"\$1\" | \"\$2\" \"\${@:3}\"" _ "x" "$EPIPE_BIN" --wait
    [ "$status" -eq 127 ]
}

@test "wait mode exit code reflects emacsclient exit code" {
    EPIPE_FAKE_EXIT=42 run_epipe_with_input "x" --wait
    [ "$status" -eq 42 ]
}

@test "async mode exit 0 even if emacsclient would fail later" {
    EPIPE_FAKE_EXIT=99 run_epipe_with_input "x"
    [ "$status" -eq 0 ]
}

@test "stdin contents reach emacsclient via tempfile (file mode)" {
    run_epipe_with_input "verbatim-content" --wait --keep
    args=$(last_args)
    last_arg=$(echo "$args" | tail -1)
    [ -f "$last_arg" ]
    [ "$(cat "$last_arg")" = "verbatim-content" ]
}

@test "two invocations create different filenames" {
    run_epipe_with_input "first" --wait --keep
    run_epipe_with_input "second" --wait --keep
    files=$(ls "$TEST_TMPDIR" 2>/dev/null | grep '^epipe-' | wc -l | tr -d ' ')
    [ "$files" -ge 2 ]
}
