use std::env;
use std::fs::{remove_file, File};
use std::io::{self, IsTerminal, Read, Write};
use std::path::PathBuf;
use std::process::{exit, Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

const VERSION: &str = env!("CARGO_PKG_VERSION");
const PROG: &str = "epipe";

#[derive(Clone, Copy, Debug, PartialEq)]
enum Mode {
    File,
    Eval,
    Inline,
}

impl Mode {
    fn from_str(s: &str) -> Result<Mode, String> {
        match s {
            "file" => Ok(Mode::File),
            "eval" => Ok(Mode::Eval),
            "inline" => Ok(Mode::Inline),
            other => Err(format!("invalid mode: {} (want: file|eval|inline)", other)),
        }
    }
    fn as_str(&self) -> &'static str {
        match self {
            Mode::File => "file",
            Mode::Eval => "eval",
            Mode::Inline => "inline",
        }
    }
}

#[derive(Debug)]
struct Config {
    mode: Mode,
    wait: bool,
    tmpdir: PathBuf,
    pattern: String,
    keep: bool,
    buffer: String,
    tee: Option<Option<String>>,
    clipboard: bool,
    silent: bool,
    verbose: u8,
    debug: bool,
    extra_elisp: String,
    emacsclient: String,
}

impl Config {
    fn defaults() -> Config {
        Config {
            mode: env::var("EPIPE_MODE")
                .ok()
                .and_then(|s| Mode::from_str(&s).ok())
                .unwrap_or(Mode::File),
            wait: false,
            tmpdir: env::var_os("TMPDIR")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("/tmp")),
            pattern: String::from("epipe-{ts}-{rand}"),
            keep: false,
            buffer: env::var("EPIPE_BUFFER").unwrap_or_else(|_| "*pipe*".to_string()),
            tee: None,
            clipboard: false,
            silent: false,
            verbose: 0,
            debug: env::var("EPIPE_DEBUG").map(|v| v == "1").unwrap_or(false),
            extra_elisp: String::new(),
            emacsclient: env::var("EMACSCLIENT").unwrap_or_else(|_| "emacsclient".to_string()),
        }
    }
}

struct Logger {
    verbose: u8,
    silent: bool,
    debug: bool,
}

impl Logger {
    fn new(cfg: &Config) -> Logger {
        Logger {
            verbose: cfg.verbose,
            silent: cfg.silent,
            debug: cfg.debug,
        }
    }

    fn ts() -> String {
        let dur = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();
        format!("{}.{:03}", dur.as_secs(), dur.subsec_millis())
    }

    fn needs_quote(v: &str) -> bool {
        v.is_empty() || v.chars().any(|c| c.is_whitespace() || c == '"' || c == '=')
    }

    fn logfmt(&self, level: &str, event: &str, kvs: &[(&str, &str)]) {
        if !self.debug {
            return;
        }
        let mut line = format!(
            "ts={} level={} component={} event={}",
            Self::ts(),
            level,
            PROG,
            event
        );
        for (k, v) in kvs {
            if Self::needs_quote(v) {
                line.push_str(&format!(" {}=\"{}\"", k, v.replace('"', "\\\"")));
            } else {
                line.push_str(&format!(" {}={}", k, v));
            }
        }
        eprintln!("{}", line);
    }

    fn info(&self, msg: &str) {
        if !self.silent && self.verbose >= 1 {
            eprintln!("{}: {}", PROG, msg);
        }
    }
    fn trace(&self, msg: &str) {
        if !self.silent && self.verbose >= 2 {
            eprintln!("{}: {}", PROG, msg);
        }
    }
    fn warn(&self, msg: &str) {
        if !self.silent {
            eprintln!("{}: warning: {}", PROG, msg);
        }
    }
    fn error(&self, msg: &str) {
        eprintln!("{}: error: {}", PROG, msg);
    }
}

fn elisp_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '\\' => out.push_str(r"\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str(r"\n"),
            '\r' => out.push_str(r"\r"),
            '\t' => out.push_str(r"\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\{:03o}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn random_hex(n: usize) -> String {
    let bytes_needed = n.div_ceil(2);
    let mut buf = vec![0u8; bytes_needed];
    if let Ok(mut f) = File::open("/dev/urandom") {
        let _ = f.read_exact(&mut buf);
    } else {
        let dur = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();
        let mix = (dur.as_nanos() as u64).wrapping_mul(std::process::id() as u64);
        for (i, b) in buf.iter_mut().enumerate() {
            *b = ((mix >> (i % 8 * 8)) & 0xff) as u8;
        }
    }
    let s: String = buf.iter().map(|b| format!("{:02x}", b)).collect();
    s.chars().take(n).collect()
}

fn format_ts_ms() -> String {
    let dur = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}{:03}", dur.as_secs(), dur.subsec_millis())
}

fn format_date_utc() -> String {
    Command::new("date")
        .arg("-u")
        .arg("+%Y%m%d-%H%M%S")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "unknown".to_string())
}

fn resolve_pattern(pattern: &str, hash: &str) -> String {
    let pid = std::process::id().to_string();
    let ts = format_ts_ms();
    let date = format_date_utc();
    let rand = random_hex(8);
    let user = env::var("USER").unwrap_or_else(|_| "u".to_string());
    pattern
        .replace("{hash}", hash)
        .replace("{pid}", &pid)
        .replace("{ts}", &ts)
        .replace("{date}", &date)
        .replace("{rand}", &rand)
        .replace("{user}", &user)
}

fn print_help() {
    let h = format!(
        "{prog} {ver} -- pipe stdin into a running Emacs server

USAGE:
    {prog} [OPTIONS] [-- ELISP]

INPUT:
    Reads stdin. Refuses to run if stdin is a terminal.
    ELISP after `--' is appended inside the elisp form (only meaningful for
    --mode=eval and --mode=inline).

EMACS MODE:
    -m, --mode MODE        file | eval | inline   (default: file)
                           file:   emacsclient <tmpfile>  (visits the file)
                           eval:   --eval (insert-file-contents into *pipe*)
                           inline: --eval (insert \"data\")  -- no temp file
    -b, --buffer NAME      Buffer name for eval/inline modes (default: *pipe*)

WAIT:
    -w, --wait, --sync     Block until Emacs returns
    -n, --no-wait, --async Fire-and-forget (default)

TEMPFILE:
    -d, --tmpdir DIR       Temp directory (default: $TMPDIR or /tmp)
    -p, --pattern PAT      Filename pattern (default: epipe-{{ts}}-{{rand}})
                           Templates: {{hash}} {{pid}} {{ts}} {{date}} {{rand}} {{user}}
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
",
        prog = PROG,
        ver = VERSION,
    );
    print!("{}", h);
}

fn parse_args(argv: Vec<String>) -> Result<Config, (String, i32)> {
    let mut cfg = Config::defaults();
    let mut iter = argv.into_iter().skip(1).peekable();
    let mut after_dd: Vec<String> = Vec::new();
    let mut seen_dd = false;

    fn require<I: Iterator<Item = String>>(
        iter: &mut std::iter::Peekable<I>,
        flag: &str,
    ) -> Result<String, (String, i32)> {
        iter.next()
            .ok_or_else(|| (format!("{} requires a value", flag), 2))
    }

    while let Some(arg) = iter.next() {
        if seen_dd {
            after_dd.push(arg);
            continue;
        }
        let a: &str = &arg;
        match a {
            "--" => seen_dd = true,
            "-h" | "--help" => {
                print_help();
                exit(0);
            }
            "-V" | "--version" => {
                println!("{} {}", PROG, VERSION);
                exit(0);
            }
            "-w" | "--wait" | "--sync" => cfg.wait = true,
            "-n" | "--no-wait" | "--async" => cfg.wait = false,
            "-k" | "--keep" => cfg.keep = true,
            "-c" | "--cb" | "--clipboard" => cfg.clipboard = true,
            "-s" | "--silent" | "--quiet" => cfg.silent = true,
            "--debug" => cfg.debug = true,
            "-v" | "--verbose" => cfg.verbose = cfg.verbose.saturating_add(1),
            "-vv" => cfg.verbose = cfg.verbose.saturating_add(2),
            "-vvv" => cfg.verbose = cfg.verbose.saturating_add(3),
            "-m" | "--mode" => {
                let v = require(&mut iter, "--mode")?;
                cfg.mode = Mode::from_str(&v).map_err(|e| (e, 2))?;
            }
            x if x.starts_with("--mode=") => {
                cfg.mode = Mode::from_str(&x[7..]).map_err(|e| (e, 2))?;
            }
            "-b" | "--buffer" => cfg.buffer = require(&mut iter, "--buffer")?,
            x if x.starts_with("--buffer=") => cfg.buffer = x[9..].to_string(),
            "-d" | "--tmpdir" => cfg.tmpdir = PathBuf::from(require(&mut iter, "--tmpdir")?),
            x if x.starts_with("--tmpdir=") => cfg.tmpdir = PathBuf::from(&x[9..]),
            "-p" | "--pattern" => cfg.pattern = require(&mut iter, "--pattern")?,
            x if x.starts_with("--pattern=") => cfg.pattern = x[10..].to_string(),
            "-t" | "--tee" => cfg.tee = Some(None),
            x if x.starts_with("--tee=") => cfg.tee = Some(Some(x[6..].to_string())),
            x if x.starts_with("-t=") => cfg.tee = Some(Some(x[3..].to_string())),
            "--emacsclient" => cfg.emacsclient = require(&mut iter, "--emacsclient")?,
            x if x.starts_with("--emacsclient=") => cfg.emacsclient = x[14..].to_string(),
            x if x.starts_with("--") => {
                return Err((format!("unknown option: {}", x), 2));
            }
            x if x.starts_with('-') && x.len() > 2 && !x.starts_with("--") => {
                let mut chars = x[1..].chars().peekable();
                let mut consumed = String::new();
                while let Some(c) = chars.next() {
                    consumed.push(c);
                    let single = format!("-{}", c);
                    match c {
                        'h' => {
                            print_help();
                            exit(0);
                        }
                        'V' => {
                            println!("{} {}", PROG, VERSION);
                            exit(0);
                        }
                        'w' => cfg.wait = true,
                        'n' => cfg.wait = false,
                        'k' => cfg.keep = true,
                        'c' => cfg.clipboard = true,
                        's' => cfg.silent = true,
                        'v' => cfg.verbose = cfg.verbose.saturating_add(1),
                        't' => cfg.tee = Some(None),
                        'm' | 'b' | 'd' | 'p' => {
                            let rest: String = chars.by_ref().collect();
                            let val = if rest.is_empty() {
                                require(&mut iter, &single)?
                            } else if let Some(stripped) = rest.strip_prefix('=') {
                                stripped.to_string()
                            } else {
                                rest
                            };
                            match c {
                                'm' => cfg.mode = Mode::from_str(&val).map_err(|e| (e, 2))?,
                                'b' => cfg.buffer = val,
                                'd' => cfg.tmpdir = PathBuf::from(val),
                                'p' => cfg.pattern = val,
                                _ => unreachable!(),
                            }
                            break;
                        }
                        _ => return Err((format!("unknown short option: -{}", c), 2)),
                    }
                }
            }
            x if x.starts_with('-') => {
                return Err((format!("unknown option: {}", x), 2));
            }
            x => {
                return Err((format!("unexpected positional argument: {}", x), 2));
            }
        }
    }
    if !after_dd.is_empty() {
        cfg.extra_elisp = after_dd.join(" ");
    }
    Ok(cfg)
}

fn read_stdin_to_vec() -> io::Result<Vec<u8>> {
    let mut buf = Vec::new();
    io::stdin().read_to_end(&mut buf)?;
    Ok(buf)
}

fn write_to_clipboard(data: &[u8], log: &Logger) {
    let candidates: &[(&str, &[&str])] = &[
        ("pbcopy", &[]),
        ("wl-copy", &[]),
        ("xclip", &["-selection", "clipboard"]),
        ("xsel", &["--clipboard", "--input"]),
    ];
    for (cmd, args) in candidates {
        if which(cmd).is_some() {
            log.logfmt("debug", "clipboard_try", &[("cmd", cmd)]);
            let mut child = match Command::new(cmd).args(*args).stdin(Stdio::piped()).spawn() {
                Ok(c) => c,
                Err(e) => {
                    log.warn(&format!("clipboard: {} failed to spawn: {}", cmd, e));
                    continue;
                }
            };
            if let Some(stdin) = child.stdin.as_mut() {
                if stdin.write_all(data).is_err() {
                    log.warn(&format!("clipboard: writing to {} failed", cmd));
                }
            }
            match child.wait() {
                Ok(s) if s.success() => {
                    log.logfmt("info", "clipboard_ok", &[("cmd", cmd)]);
                    return;
                }
                Ok(s) => log.warn(&format!("clipboard: {} exited {:?}", cmd, s.code())),
                Err(e) => log.warn(&format!("clipboard: {} wait failed: {}", cmd, e)),
            }
        }
    }
    log.warn("clipboard: no copy tool found (pbcopy/wl-copy/xclip/xsel)");
}

fn which(cmd: &str) -> Option<PathBuf> {
    if cmd.contains('/') {
        let p = PathBuf::from(cmd);
        if p.exists() {
            return Some(p);
        }
        return None;
    }
    let path = env::var_os("PATH")?;
    for dir in env::split_paths(&path) {
        let candidate = dir.join(cmd);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

fn write_to_tee(data: &[u8], lang: &Option<String>, log: &Logger) {
    let isatty = io::stdout().is_terminal();
    if let Some(lang) = lang {
        if isatty && which("bat").is_some() {
            log.logfmt("debug", "tee_bat", &[("lang", lang)]);
            let mut child = match Command::new("bat")
                .arg("--paging=never")
                .arg("--style=plain")
                .arg("-l")
                .arg(lang)
                .stdin(Stdio::piped())
                .spawn()
            {
                Ok(c) => c,
                Err(e) => {
                    log.warn(&format!("tee: bat spawn failed: {}", e));
                    let _ = io::stdout().write_all(data);
                    return;
                }
            };
            if let Some(stdin) = child.stdin.as_mut() {
                let _ = stdin.write_all(data);
            }
            let _ = child.wait();
            return;
        }
    }
    let _ = io::stdout().write_all(data);
}

fn build_elisp(cfg: &Config, path_or_data: &str) -> String {
    let buffer = elisp_string(&cfg.buffer);
    let extra = if cfg.extra_elisp.is_empty() {
        String::new()
    } else {
        format!(" {}", cfg.extra_elisp)
    };
    match cfg.mode {
        Mode::Eval => {
            let cleanup = if cfg.keep {
                String::new()
            } else {
                format!(" (delete-file {})", elisp_string(path_or_data))
            };
            format!(
                "(progn (switch-to-buffer (generate-new-buffer-name {})) (insert-file-contents {}){}{})",
                buffer,
                elisp_string(path_or_data),
                cleanup,
                extra
            )
        }
        Mode::Inline => format!(
            "(progn (switch-to-buffer (generate-new-buffer-name {})) (insert {}){})",
            buffer,
            elisp_string(path_or_data),
            extra
        ),
        Mode::File => unreachable!("file mode does not build elisp"),
    }
}

fn run() -> i32 {
    let argv: Vec<String> = env::args().collect();
    let cfg = match parse_args(argv) {
        Ok(c) => c,
        Err((msg, code)) => {
            eprintln!("{}: error: {}", PROG, msg);
            eprintln!("try `{} --help'", PROG);
            return code;
        }
    };

    let log = Logger::new(&cfg);

    log.logfmt(
        "info",
        "start",
        &[
            ("mode", cfg.mode.as_str()),
            ("wait", if cfg.wait { "true" } else { "false" }),
            ("buffer", &cfg.buffer),
            ("emacsclient", &cfg.emacsclient),
        ],
    );

    if io::stdin().is_terminal() {
        log.error("stdin must be a pipe (refusing to read from a tty)");
        return 2;
    }

    if which(&cfg.emacsclient).is_none() {
        log.error(&format!(
            "{} not found (set EMACSCLIENT or --emacsclient)",
            cfg.emacsclient
        ));
        return 127;
    }

    let data = match read_stdin_to_vec() {
        Ok(d) => d,
        Err(e) => {
            log.error(&format!("reading stdin: {}", e));
            return 1;
        }
    };
    log.info(&format!("read {} bytes from stdin", data.len()));
    log.logfmt("debug", "stdin_read", &[("bytes", &data.len().to_string())]);

    if let Some(lang) = &cfg.tee {
        write_to_tee(&data, lang, &log);
    }
    if cfg.clipboard {
        write_to_clipboard(&data, &log);
    }

    let path = if cfg.mode == Mode::Inline {
        None
    } else {
        let hash = format!("{:x}", md5::compute(&data));
        let name = resolve_pattern(&cfg.pattern, &hash);
        let p = cfg.tmpdir.join(name);
        let mut f = match File::create(&p) {
            Ok(f) => f,
            Err(e) => {
                log.error(&format!("creating {}: {}", p.display(), e));
                return 1;
            }
        };
        if let Err(e) = f.write_all(&data) {
            log.error(&format!("writing {}: {}", p.display(), e));
            let _ = remove_file(&p);
            return 1;
        }
        log.info(&format!("wrote tempfile {}", p.display()));
        log.logfmt(
            "debug",
            "tempfile_created",
            &[
                ("path", &p.display().to_string()),
                ("bytes", &data.len().to_string()),
            ],
        );
        Some(p)
    };

    let mut emc = Command::new(&cfg.emacsclient);
    if !cfg.wait {
        emc.arg("--no-wait");
    }
    let inline_payload: String;
    let elisp_form: String;
    match cfg.mode {
        Mode::File => {
            let p = path.as_ref().unwrap();
            emc.arg(p);
            elisp_form = String::new();
        }
        Mode::Eval => {
            let p = path.as_ref().unwrap();
            elisp_form = build_elisp(&cfg, &p.display().to_string());
            emc.arg("--eval").arg(&elisp_form);
        }
        Mode::Inline => {
            inline_payload = String::from_utf8_lossy(&data).to_string();
            elisp_form = build_elisp(&cfg, &inline_payload);
            emc.arg("--eval").arg(&elisp_form);
        }
    }

    log.trace(&format!("elisp: {}", &elisp_form));
    log.logfmt(
        "info",
        "invoke_emacsclient",
        &[
            ("wait", if cfg.wait { "true" } else { "false" }),
            ("mode", cfg.mode.as_str()),
        ],
    );
    if cfg.wait && cfg.verbose >= 1 {
        eprintln!("{}: Waiting for Emacs...", PROG);
    }

    if cfg.wait {
        emc.stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit());
        let status = match emc.status() {
            Ok(s) => s,
            Err(e) => {
                log.error(&format!("running emacsclient: {}", e));
                return 1;
            }
        };
        let code = status.code().unwrap_or(1);
        log.logfmt("info", "done", &[("exit", &code.to_string())]);
        if let Some(p) = &path {
            if !cfg.keep && cfg.mode == Mode::File {
                let _ = remove_file(p);
            }
        }
        code
    } else {
        emc.stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        match emc.spawn() {
            Ok(_) => {
                log.logfmt("info", "spawned_async", &[]);
                0
            }
            Err(e) => {
                log.error(&format!("spawning emacsclient: {}", e));
                if let Some(p) = &path {
                    if !cfg.keep {
                        let _ = remove_file(p);
                    }
                }
                1
            }
        }
    }
}

fn main() {
    exit(run());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn elisp_string_basic() {
        assert_eq!(elisp_string("abc"), "\"abc\"");
        assert_eq!(elisp_string(""), "\"\"");
    }
    #[test]
    fn elisp_string_escapes() {
        assert_eq!(elisp_string("a\"b"), "\"a\\\"b\"");
        assert_eq!(elisp_string("a\\b"), "\"a\\\\b\"");
        assert_eq!(elisp_string("a\nb"), "\"a\\nb\"");
        assert_eq!(elisp_string("a\tb"), "\"a\\tb\"");
        assert_eq!(elisp_string("a\rb"), "\"a\\rb\"");
        assert_eq!(elisp_string("\x01"), "\"\\001\"");
    }
    #[test]
    fn mode_parse() {
        assert_eq!(Mode::from_str("file").unwrap(), Mode::File);
        assert_eq!(Mode::from_str("eval").unwrap(), Mode::Eval);
        assert_eq!(Mode::from_str("inline").unwrap(), Mode::Inline);
        assert!(Mode::from_str("nope").is_err());
    }
    #[test]
    fn parse_args_help_and_version_handled_via_exit() {
        let cfg = parse_args(vec!["epipe".into(), "--wait".into()]).unwrap();
        assert!(cfg.wait);
        let cfg = parse_args(vec!["epipe".into(), "-w".into()]).unwrap();
        assert!(cfg.wait);
        let cfg = parse_args(vec!["epipe".into(), "--no-wait".into()]).unwrap();
        assert!(!cfg.wait);
    }
    #[test]
    fn parse_args_short_combos() {
        let cfg = parse_args(vec!["epipe".into(), "-vv".into()]).unwrap();
        assert_eq!(cfg.verbose, 2);
        let cfg = parse_args(vec!["epipe".into(), "-v".into(), "-v".into()]).unwrap();
        assert_eq!(cfg.verbose, 2);
        let cfg = parse_args(vec!["epipe".into(), "-vvv".into()]).unwrap();
        assert_eq!(cfg.verbose, 3);
    }
    #[test]
    fn parse_args_mode_value() {
        let cfg = parse_args(vec!["epipe".into(), "--mode".into(), "eval".into()]).unwrap();
        assert_eq!(cfg.mode, Mode::Eval);
        let cfg = parse_args(vec!["epipe".into(), "--mode=inline".into()]).unwrap();
        assert_eq!(cfg.mode, Mode::Inline);
        let cfg = parse_args(vec!["epipe".into(), "-m".into(), "file".into()]).unwrap();
        assert_eq!(cfg.mode, Mode::File);
    }
    #[test]
    fn parse_args_dd_extra_elisp() {
        let cfg = parse_args(vec![
            "epipe".into(),
            "--mode=eval".into(),
            "--".into(),
            "(message".into(),
            "\"hi\")".into(),
        ])
        .unwrap();
        assert_eq!(cfg.extra_elisp, "(message \"hi\")");
    }
    #[test]
    fn parse_args_unknown() {
        assert!(parse_args(vec!["epipe".into(), "--nope".into()]).is_err());
    }
    #[test]
    fn pattern_substitution() {
        let out = resolve_pattern("epipe-{hash}-{pid}", "deadbeef");
        assert!(out.starts_with("epipe-deadbeef-"));
    }
}
