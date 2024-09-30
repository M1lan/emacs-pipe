use std::env::temp_dir;
use std::fs::{File, remove_file};
use std::io::{self, Write, Read};
use std::process::Command;
use md5;

fn main() -> io::Result<()> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;

    let hash = format!("{:x}", md5::compute(&input));
    let file_path = temp_dir().join(format!("{}.emacs-pager", hash));

    {
        let mut file = File::create(&file_path)?;
        file.write_all(input.as_bytes())?;
    }

    println!("reading into emacs...");
    Command::new("emacsclient")
        .arg(file_path.to_str().unwrap())
        .status()?;

    remove_file(file_path)?;
    Ok(())
}
