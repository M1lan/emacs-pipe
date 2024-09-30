# a simple emacspipe

...aka my very first (public) Rust program :F

Essentially a rewrite of the Ruby component of [mbriggs/emacs-pager](https://github.com/mbriggs/emacs-pager)

This requires a GNU/Emacs server running; you can start one with M-x
server-start or alternatively start Emacs as `emacs --daemon`.

Can be used from a shell running within or outside of Emacs to write
its standard input to a temporary Emacs buffer.

## compile
- have rust installed: https://rustup.rs/
- clone this repo
- `cargo build --release`
- copy binary from ./target/release/ to some directory in your $PATH

## usage

Can also be set as $PAGER: `export PAGER=emacspipe`.

Or, as the name suggests, to pipe something into Emacs:
```
echo "ceci n'est pas une pipe" | emacspipe
```
