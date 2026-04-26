# emacs-pipe (`epipe`)

Pipe stdin into a running Emacs server. Two implementations, byte-identical CLI: a Rust binary and a hardened Bash 5.3+ script.

```bash
echo "hello, emacs" | epipe              # async, fire-and-forget (default)
some-long-command  | epipe --wait        # block until Emacs returns
git diff           | epipe --tee=diff    # also print to terminal via bat
cat err.log        | epipe -m eval -b "*errors*" --debug
```

## Why two implementations?

Same tool, two engines. Pick whichever fits the box you're on.

| | `target/release/epipe` (Rust) | `bash/epipe.bash` |
|---|---|---|
| Runtime | Single static binary, ~400 KB | Bash 5.3+ + coreutils |
| Startup | ~1 ms | ~5 ms |
| Deploy | `cargo install` / scp | `cp` to `~/scripts/`, no compile step |
| Dependencies | `md5` crate, libc | `md5sum`/`md5`, `mktemp`, `od`, `date` |

CLI surface is locked: every flag, every default, every elisp form is identical. The same test suite runs against both binaries and asserts they emit equivalent commands to `emacsclient`.

## Install

### Rust

```bash
cargo build --release
install -m 755 target/release/epipe ~/.local/bin/epipe
```

### Bash

```bash
install -m 755 bash/epipe.bash ~/.local/bin/epipe
```

Or use both side-by-side as `epipe` and `epipe.bash`.

## Usage

```text
USAGE:
    epipe [OPTIONS] [-- ELISP]

EMACS MODE:
    -m, --mode MODE        file | eval | inline   (default: file)
                           file:   emacsclient <tmpfile>  (visits the file)
                           eval:   --eval (insert-file-contents into *pipe*)
                           inline: --eval (insert "data")  -- no temp file
    -b, --buffer NAME      Buffer name for eval/inline modes (default: *pipe*)

WAIT:
    -w, --wait, --sync     Block until Emacs returns
    -n, --no-wait, --async Fire-and-forget (default)

TEMPFILE:
    -d, --tmpdir DIR       Temp directory (default: $TMPDIR or /tmp)
    -p, --pattern PAT      Filename pattern (default: epipe-{ts}-{rand})
                           Templates: {hash} {pid} {ts} {date} {rand} {user}
    -k, --keep             Keep tempfile after sending to Emacs

SIDE OUTPUTS:
    -t, --tee[=LANG]       Echo input to stdout (with bat -l LANG if installed)
    -c, --cb, --clipboard  Also copy input to system clipboard

VERBOSITY:
    -s, --silent           Errors only
    -v, --verbose          More output (-vv adds the elisp form)
        --debug            Logfmt records to stderr
    -V, --version          Print version and exit
    -h, --help             Show this help and exit
```

### Modes

| Mode | What Emacs ends up doing | When to use |
|---|---|---|
| `file` (default) | `emacsclient <tempfile>` -- Emacs visits the file, the buffer is named after it, you can `C-x C-s` it back | Pager-style: long output you want to navigate, search, save |
| `eval` | `emacsclient --eval '(progn (switch-to-buffer (generate-new-buffer-name "*pipe*")) (insert-file-contents "..."))'` | Detached buffer with a name you control; original tempfile auto-deleted unless `--keep` |
| `inline` | `emacsclient --eval '(progn (switch-to-buffer ...) (insert "..."))'` -- payload is escaped into the elisp string itself | Tiny snippets where you don't want a temp file at all |

### Sync vs async

Default is **async**: `epipe` returns immediately, Emacs handles the buffer in the background. Good for ad-hoc piping from shells, prompts, scripts.

`--wait` / `--sync` blocks until Emacs returns. Use this when:

- An LLM agent (Claude Code, forge, etc.) needs to wait for a human to act in Emacs before proceeding.
- You want the exit code from `emacsclient` to propagate back.
- You want the tempfile cleaned up immediately after Emacs reads it (file mode + `--wait` + no `--keep`).

### Side outputs

- `--tee` (or `-t`): also write stdin to `epipe`'s stdout. With `--tee=LANG` and `bat` installed and stdout is a tty, syntax-highlight as `LANG`. Otherwise plain.
- `--clipboard` (or `-c` / `--cb`): also copy stdin to the system clipboard. Uses the first available of `pbcopy`, `wl-copy`, `xclip`, `xsel`.

Combine freely:

```bash
kubectl get pods -o yaml | epipe --tee=yaml --clipboard --mode=eval -b "*pods*"
```

### Verbosity

| Flag | What you get |
|---|---|
| (default) | nothing on stdout/stderr unless something fails |
| `-s` / `--silent` | errors only, suppresses warnings too |
| `-v` | one info line per phase (read N bytes, wrote tempfile, invoke emacsclient) |
| `-vv` | adds the elisp form being sent |
| `--debug` | logfmt-formatted records: `ts=… level=… component=epipe event=… key=value …`. Independent of `-v`. |
| `EPIPE_DEBUG=1` | env-flag equivalent of `--debug` |

Logfmt example:

```
ts=1761504123.456 level=info component=epipe event=start mode=file wait=true buffer="*pipe*" emacsclient=emacsclient
ts=1761504123.461 level=debug component=epipe event=stdin_read bytes=4096
ts=1761504123.462 level=debug component=epipe event=tempfile_created path=/tmp/epipe-1761504123461-abc12345 bytes=4096
ts=1761504123.475 level=info component=epipe event=invoke_emacsclient wait=true mode=file
ts=1761504123.482 level=info component=epipe event=done exit=0
```

### Filename patterns

Default is `epipe-{ts}-{rand}`. Substitute any of:

| Token | Value |
|---|---|
| `{hash}` | md5 of the input bytes (deterministic dedup if you want it) |
| `{pid}` | epipe PID |
| `{ts}` | unix epoch milliseconds |
| `{date}` | UTC `YYYYMMDD-HHMMSS` |
| `{rand}` | 8-char random hex |
| `{user}` | `$USER` |

```bash
echo x | epipe --pattern "snip-{date}-{user}-{hash}.txt" --keep
```

### Environment variables

| Var | Purpose |
|---|---|
| `EMACSCLIENT` | Override path to `emacsclient` |
| `TMPDIR` | Default temp directory |
| `EPIPE_MODE` | Default mode (`file`/`eval`/`inline`) |
| `EPIPE_BUFFER` | Default buffer name |
| `EPIPE_DEBUG=1` | Force `--debug` |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Generic IO/preflight failure |
| `2` | Bad arguments / refused input (e.g. stdin is a tty) |
| `127` | `emacsclient` not found on `$PATH` |
| anything else | Forwarded from `emacsclient` (only in `--wait` mode) |

## Development

### Build & test

```bash
just build              # cargo build --release
just test-rust          # cargo test
just test-bash          # bats parity suite vs bash impl
just test-rust-parity   # bats parity suite vs rust impl
just test               # all of the above
just verify             # fmt + clippy + shellcheck + test
```

### Test architecture

A single bats suite (`tests/shared.bats`, 41 tests) runs against either implementation by setting `EPIPE_BIN`. A fake `emacsclient` (`tests/fixtures/fake-emacsclient.bash`) records every invocation -- argv, cwd, stdin -- to a record file the tests then assert on. This is what guarantees parity: both binaries must produce the exact same emacsclient invocations for the same inputs.

```
tests/
├── shared.bats                      -- 41 parity tests, shared across both impls
└── fixtures/
    ├── fake-emacsclient.bash        -- records argv + stdin to $EPIPE_RECORD_FILE
    └── helpers.bash                 -- setup/teardown, last_args(), invocation_count()
```

### Layout

```
.
├── Cargo.toml
├── Justfile
├── readme.md
├── src/main.rs                      -- Rust impl (single file)
├── bash/epipe.bash                  -- Bash 5.3+ impl
├── tests/                           -- shared parity suite
└── .github/workflows/ci.yml         -- cargo build/test + bats on Linux
```

## License

MIT.
