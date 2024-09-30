use std::env::temp_dir;
use std::fs::{remove_file, File};
use std::io::{self, Read, Write};
use std::process::{Command, Stdio};

fn main() -> io::Result<()> {
    let mut input = String::new();

    // Check if input is coming from stdin
    if atty::isnt(atty::Stream::Stdin) {
        io::stdin().read_to_string(&mut input)?;
    }

    if input.is_empty() {
        return Ok(());
    }

    let hash = format!("{:x}", md5::compute(&input));
    let file_path = temp_dir().join(format!("{}.emacs-pager", hash));

    {
        let mut file = File::create(&file_path)?;
        file.write_all(input.as_bytes())?;
    }

    println!("reading into emacs...");
    Command::new("emacsclient")
        .arg(file_path.to_str().unwrap())
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()?;

    remove_file(file_path)?;
    Ok(())
}
