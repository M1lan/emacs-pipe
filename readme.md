# a simple emacspipe

...aka my very first (public) Rust program :F

Essentially a rewrite of the Ruby component of [mbriggs/emacs-pager](https://github.com/mbriggs/emacs-pager)

This requires a Emacs server running.  You start one with M-x
server-start or alternatively run Emacs as `emacs --daemon`.

Can be used from a shell running within or outside of Emacs to write
its standard input to a temporary GNU/Emacs buffer.

## compile
- have rust installed: https://rustup.rs/
- clone this repo
- `cargo build --release`
- copy binary from from ./target/release/ to some dir in your $PATH

## usage

can also be set as $PAGER: `export PAGER=emacspipe`

or, as the name suggests, to pipe into emacsclient:
```
echo "ca ce n'est pas une pipe" | emacspipe
```
