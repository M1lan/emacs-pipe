#!/usr/bin/env bash

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

readonly VERSION="0.2.0"
readonly PROG="epipe"

if (( BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 2) )); then
  printf '%s: bash >= 5.2 required (have %s)\n' "$PROG" "$BASH_VERSION" >&2
  exit 64
fi

export LC_ALL=C
IFS=$' \t\n'
umask 077
unset CDPATH BASH_ENV

if command -v gdate >/dev/null 2>&1; then
  DATE_CMD="gdate"
else
  DATE_CMD="date"
fi
readonly DATE_CMD

if command -v gmd5sum >/dev/null 2>&1; then
  MD5_CMD=("gmd5sum")
elif command -v md5sum >/dev/null 2>&1; then
  MD5_CMD=("md5sum")
elif command -v md5 >/dev/null 2>&1; then
  MD5_CMD=("md5" "-q")
else
  MD5_CMD=()
fi

declare -g MODE
declare -g WAIT=0
declare -g TMPDIR_OPT
declare -g PATTERN="epipe-{ts}-{rand}"
declare -gi KEEP=0
declare -g BUFFER
declare -gi TEE_SET=0
declare -g TEE_LANG=""
declare -gi CLIPBOARD=0
declare -gi SILENT=0
declare -gi VERBOSE=0
declare -gi DEBUG=0
declare -g EXTRA_ELISP=""
declare -g EMACSCLIENT
declare -g TMPFILE=""

MODE="${EPIPE_MODE:-file}"
case "$MODE" in
  file|eval|inline) ;;
  *) MODE="file" ;;
esac
TMPDIR_OPT="${TMPDIR:-/tmp}"
BUFFER="${EPIPE_BUFFER:-*pipe*}"
EMACSCLIENT="${EMACSCLIENT:-emacsclient}"
[[ "${EPIPE_DEBUG:-0}" == "1" ]] && DEBUG=1

ts_ms() {
  local out
  if out=$("$DATE_CMD" +%s%3N 2>/dev/null) && [[ "$out" != *N ]]; then
    printf '%s' "$out"
  else
    printf '%s000' "$("$DATE_CMD" +%s)"
  fi
}

ts_iso_ms() {
  local out
  if out=$("$DATE_CMD" +%s.%3N 2>/dev/null) && [[ "$out" != *N ]]; then
    printf '%s' "$out"
  else
    printf '%s.000' "$("$DATE_CMD" +%s)"
  fi
}

date_utc() {
  "$DATE_CMD" -u +%Y%m%d-%H%M%S 2>/dev/null || printf 'unknown'
}

random_hex() {
  local n=${1:-8}
  local bytes=$(( (n + 1) / 2 ))
  local hex=""
  if [[ -r /dev/urandom ]]; then
    hex=$(LC_ALL=C od -An -N"$bytes" -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  fi
  if [[ -z "$hex" ]]; then
    hex=$(printf '%x' "$(( ($(ts_ms) + $$) & 0xffffffff ))")
  fi
  printf '%s' "${hex:0:$n}"
}

needs_quote() {
  local v=$1
  [[ -z "$v" ]] && return 0
  [[ "$v" == *[[:space:]\"=]* ]]
}

logfmt() {
  (( DEBUG )) || return 0
  local level=$1; shift
  local event=$1; shift
  local line
  line="ts=$(ts_iso_ms) level=$level component=$PROG event=$event"
  while (( $# >= 2 )); do
    local k=$1 v=$2
    shift 2
    if needs_quote "$v"; then
      line+=" $k=\"${v//\"/\\\"}\""
    else
      line+=" $k=$v"
    fi
  done
  printf '%s\n' "$line" >&2
}

log_info() {
  (( SILENT )) && return 0
  (( VERBOSE >= 1 )) || return 0
  printf '%s: %s\n' "$PROG" "$1" >&2
}

log_trace() {
  (( SILENT )) && return 0
  (( VERBOSE >= 2 )) || return 0
  printf '%s: %s\n' "$PROG" "$1" >&2
}

log_warn() {
  (( SILENT )) && return 0
  printf '%s: warning: %s\n' "$PROG" "$1" >&2
}

log_error() {
  printf '%s: error: %s\n' "$PROG" "$1" >&2
}

elisp_string() {
  local s=$1 out='"' c i ord oct
  for (( i=0; i<${#s}; i++ )); do
    c=${s:i:1}
    # shellcheck disable=SC1003
    case "$c" in
      $'\\') out+='\\' ;;
      '"') out+='\"' ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      *)
        printf -v ord '%d' "'$c"
        if (( ord < 0x20 )); then
          printf -v oct '\\%03o' "$ord"
          out+=$oct
        else
          out+=$c
        fi
        ;;
    esac
  done
  out+='"'
  printf '%s' "$out"
}

resolve_pattern() {
  local pattern=$1 hash=$2
  local pid=$$ ts date_s rand user out
  ts=$(ts_ms)
  date_s=$(date_utc)
  rand=$(random_hex 8)
  user=${USER:-u}
  out=$pattern
  out=${out//\{hash\}/$hash}
  out=${out//\{pid\}/$pid}
  out=${out//\{ts\}/$ts}
  out=${out//\{date\}/$date_s}
  out=${out//\{rand\}/$rand}
  out=${out//\{user\}/$user}
  printf '%s' "$out"
}

print_help() {
  cat <<HELP
$PROG $VERSION -- pipe stdin into a running Emacs server

USAGE:
    $PROG [OPTIONS] [-- ELISP]

INPUT:
    Reads stdin. Refuses to run if stdin is a terminal.
    ELISP after \`--' is appended inside the elisp form (only meaningful for
    --mode=eval and --mode=inline).

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
    -d, --tmpdir DIR       Temp directory (default: \$TMPDIR or /tmp)
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

ENVIRONMENT:
    EMACSCLIENT            Override path to emacsclient
    TMPDIR                 Default temp directory
    EPIPE_DEBUG=1          Force --debug
    EPIPE_BUFFER           Default buffer name
    EPIPE_MODE             Default mode

EXIT CODES:
    0   success
    1   generic failure (preflight, IO)
    2   bad arguments / refused input
    127 emacsclient not found
HELP
}

bad_arg() {
  log_error "$1"
  printf 'try `%s --help'\''\n' "$PROG" >&2
  exit 2
}

parse_args() {
  local -a after_dd=()
  local seen_dd=0 a v rest first
  while (( $# )); do
    a=$1; shift
    if (( seen_dd )); then
      after_dd+=("$a")
      continue
    fi
    case "$a" in
      --) seen_dd=1 ;;
      -h|--help) print_help; exit 0 ;;
      -V|--version) printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
      -w|--wait|--sync) WAIT=1 ;;
      -n|--no-wait|--async) WAIT=0 ;;
      -k|--keep) KEEP=1 ;;
      -c|--cb|--clipboard) CLIPBOARD=1 ;;
      -s|--silent|--quiet) SILENT=1 ;;
      --debug) DEBUG=1 ;;
      -v|--verbose) VERBOSE=$((VERBOSE+1)) ;;
      -vv) VERBOSE=$((VERBOSE+2)) ;;
      -vvv) VERBOSE=$((VERBOSE+3)) ;;
      -m|--mode)
        (( $# )) || bad_arg "$a requires a value"
        MODE=$1; shift
        case "$MODE" in file|eval|inline) ;; *) bad_arg "invalid mode: $MODE (want: file|eval|inline)" ;; esac
        ;;
      --mode=*)
        MODE=${a#--mode=}
        case "$MODE" in file|eval|inline) ;; *) bad_arg "invalid mode: $MODE (want: file|eval|inline)" ;; esac
        ;;
      -b|--buffer)
        (( $# )) || bad_arg "$a requires a value"
        BUFFER=$1; shift ;;
      --buffer=*) BUFFER=${a#--buffer=} ;;
      -d|--tmpdir)
        (( $# )) || bad_arg "$a requires a value"
        TMPDIR_OPT=$1; shift ;;
      --tmpdir=*) TMPDIR_OPT=${a#--tmpdir=} ;;
      -p|--pattern)
        (( $# )) || bad_arg "$a requires a value"
        PATTERN=$1; shift ;;
      --pattern=*) PATTERN=${a#--pattern=} ;;
      -t|--tee) TEE_SET=1; TEE_LANG="" ;;
      --tee=*) TEE_SET=1; TEE_LANG=${a#--tee=} ;;
      -t=*) TEE_SET=1; TEE_LANG=${a#-t=} ;;
      --emacsclient)
        (( $# )) || bad_arg "$a requires a value"
        EMACSCLIENT=$1; shift ;;
      --emacsclient=*) EMACSCLIENT=${a#--emacsclient=} ;;
      --*) bad_arg "unknown option: $a" ;;
      -*)
        if (( ${#a} > 2 )); then
          rest=${a:1}
          while [[ -n "$rest" ]]; do
            first=${rest:0:1}
            rest=${rest:1}
            case "$first" in
              h) print_help; exit 0 ;;
              V) printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
              w) WAIT=1 ;;
              n) WAIT=0 ;;
              k) KEEP=1 ;;
              c) CLIPBOARD=1 ;;
              s) SILENT=1 ;;
              v) VERBOSE=$((VERBOSE+1)) ;;
              t) TEE_SET=1; TEE_LANG="" ;;
              m|b|d|p)
                if [[ -n "$rest" ]]; then
                  v=${rest#=}
                else
                  (( $# )) || bad_arg "-$first requires a value"
                  v=$1; shift
                fi
                rest=""
                case "$first" in
                  m)
                    MODE=$v
                    case "$MODE" in file|eval|inline) ;; *) bad_arg "invalid mode: $MODE (want: file|eval|inline)" ;; esac
                    ;;
                  b) BUFFER=$v ;;
                  d) TMPDIR_OPT=$v ;;
                  p) PATTERN=$v ;;
                esac
                ;;
              *) bad_arg "unknown short option: -$first" ;;
            esac
          done
        else
          bad_arg "unknown option: $a"
        fi
        ;;
      *) bad_arg "unexpected positional argument: $a" ;;
    esac
  done
  if (( ${#after_dd[@]} )); then
    EXTRA_ELISP="${after_dd[*]}"
  fi
}

which_cmd() {
  local cmd=$1
  if [[ "$cmd" == */* ]]; then
    [[ -x "$cmd" ]] && printf '%s' "$cmd"
    return
  fi
  command -v "$cmd" 2>/dev/null
}

write_clipboard() {
  local file=$1
  local -a candidates=(
    "pbcopy"
    "wl-copy"
    "xclip -selection clipboard"
    "xsel --clipboard --input"
  )
  local entry tool args
  for entry in "${candidates[@]}"; do
    read -r tool args <<<"$entry"
    if which_cmd "$tool" >/dev/null; then
      logfmt debug clipboard_try cmd "$tool"
      if eval "$tool $args" <"$file" 2>/dev/null; then
        logfmt info clipboard_ok cmd "$tool"
        return 0
      fi
      log_warn "clipboard: $tool failed"
    fi
  done
  log_warn "clipboard: no copy tool found (pbcopy/wl-copy/xclip/xsel)"
  return 1
}

write_tee() {
  local file=$1 lang=$2
  if [[ -n "$lang" ]] && [[ -t 1 ]] && which_cmd bat >/dev/null; then
    logfmt debug tee_bat lang "$lang"
    bat --paging=never --style=plain -l "$lang" "$file" 2>/dev/null || cat "$file"
  else
    cat "$file"
  fi
}

build_elisp() {
  local mode=$1 path_or_data=$2
  local buffer_lit cleanup extra
  buffer_lit=$(elisp_string "$BUFFER")
  if [[ -n "$EXTRA_ELISP" ]]; then
    extra=" $EXTRA_ELISP"
  else
    extra=""
  fi
  case "$mode" in
    eval)
      if (( KEEP )); then
        cleanup=""
      else
        cleanup=" (delete-file $(elisp_string "$path_or_data"))"
      fi
      printf '(progn (switch-to-buffer (generate-new-buffer-name %s)) (insert-file-contents %s)%s%s)' \
        "$buffer_lit" "$(elisp_string "$path_or_data")" "$cleanup" "$extra"
      ;;
    inline)
      printf '(progn (switch-to-buffer (generate-new-buffer-name %s)) (insert %s)%s)' \
        "$buffer_lit" "$(elisp_string "$path_or_data")" "$extra"
      ;;
    file) return 1 ;;
  esac
}

cleanup_trap() {
  if [[ -n "${TMPFILE-}" && -e "${TMPFILE-}" ]]; then
    if (( ! KEEP )); then
      rm -f -- "$TMPFILE" 2>/dev/null || true
    fi
  fi
}

read_stdin_to_file() {
  local out=$1
  cat > "$out"
}

md5_of_file() {
  local file=$1
  if (( ${#MD5_CMD[@]} == 0 )); then
    printf '00000000000000000000000000000000'
    return
  fi
  local out
  out=$("${MD5_CMD[@]}" -- "$file" 2>/dev/null || "${MD5_CMD[@]}" "$file" 2>/dev/null || true)
  out=${out%% *}
  out=${out% *}
  printf '%s' "${out:-00000000000000000000000000000000}"
}

main() {
  parse_args "$@"

  logfmt info start \
    mode "$MODE" \
    wait "$( ((WAIT)) && echo true || echo false )" \
    buffer "$BUFFER" \
    emacsclient "$EMACSCLIENT"

  if [[ -t 0 ]]; then
    log_error "stdin must be a pipe (refusing to read from a tty)"
    return 2
  fi

  if ! which_cmd "$EMACSCLIENT" >/dev/null; then
    log_error "$EMACSCLIENT not found (set EMACSCLIENT or --emacsclient)"
    return 127
  fi

  local stage
  stage=$(mktemp "${TMPDIR_OPT%/}/epipe-stage.XXXXXX") || { log_error "mktemp failed"; return 1; }
  TMPFILE=$stage
  trap cleanup_trap EXIT HUP INT TERM
  read_stdin_to_file "$stage"
  local bytes
  bytes=$(wc -c <"$stage" | tr -d ' ')
  log_info "read $bytes bytes from stdin"
  logfmt debug stdin_read bytes "$bytes"

  if (( TEE_SET )); then write_tee "$stage" "$TEE_LANG"; fi
  if (( CLIPBOARD )); then write_clipboard "$stage"; fi

  if [[ "$MODE" == "inline" ]]; then
    local data lisp
    data=$(cat "$stage")
    rm -f -- "$stage" 2>/dev/null || true
    TMPFILE=""
    trap - EXIT HUP INT TERM
    lisp=$(build_elisp inline "$data")
    log_trace "elisp: $lisp"
    logfmt info invoke_emacsclient wait "$( ((WAIT)) && echo true || echo false )" mode inline
    if (( WAIT )); then
      (( VERBOSE >= 1 && ! SILENT )) && printf '%s: Waiting for Emacs...\n' "$PROG" >&2
      "$EMACSCLIENT" --eval "$lisp"
      local rc=$?
      logfmt info 'done' exit "$rc"
      return $rc
    else
      "$EMACSCLIENT" --no-wait --eval "$lisp" >/dev/null 2>&1 &
      disown
      logfmt info spawned_async
      return 0
    fi
  fi

  local hash filename path
  hash=$(md5_of_file "$stage")
  filename=$(resolve_pattern "$PATTERN" "$hash")
  path="${TMPDIR_OPT%/}/${filename}"
  mv -f -- "$stage" "$path" || { log_error "moving tempfile to $path"; return 1; }
  TMPFILE=$path
  log_info "wrote tempfile $path"
  logfmt debug tempfile_created path "$path" bytes "$bytes"

  case "$MODE" in
    file)
      logfmt info invoke_emacsclient wait "$( ((WAIT)) && echo true || echo false )" mode file
      if (( WAIT )); then
        (( VERBOSE >= 1 && ! SILENT )) && printf '%s: Waiting for Emacs...\n' "$PROG" >&2
        "$EMACSCLIENT" -- "$path"
        local rc=$?
        logfmt info 'done' exit "$rc"
        if (( ! KEEP )); then
          rm -f -- "$path" 2>/dev/null || true
        fi
        TMPFILE=""
        trap - EXIT HUP INT TERM
        return $rc
      else
        "$EMACSCLIENT" --no-wait -- "$path" >/dev/null 2>&1 &
        disown
        logfmt info spawned_async
        TMPFILE=""
        trap - EXIT HUP INT TERM
        return 0
      fi
      ;;
    eval)
      local lisp
      lisp=$(build_elisp eval "$path")
      log_trace "elisp: $lisp"
      logfmt info invoke_emacsclient wait "$( ((WAIT)) && echo true || echo false )" mode eval
      if (( WAIT )); then
        (( VERBOSE >= 1 && ! SILENT )) && printf '%s: Waiting for Emacs...\n' "$PROG" >&2
        "$EMACSCLIENT" --eval "$lisp"
        local rc=$?
        logfmt info 'done' exit "$rc"
        TMPFILE=""
        trap - EXIT HUP INT TERM
        return $rc
      else
        "$EMACSCLIENT" --no-wait --eval "$lisp" >/dev/null 2>&1 &
        disown
        logfmt info spawned_async
        TMPFILE=""
        trap - EXIT HUP INT TERM
        return 0
      fi
      ;;
  esac
}

main "$@"
