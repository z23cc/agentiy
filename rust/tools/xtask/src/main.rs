mod codegen;
mod identity;

use anyhow::{Context, Result, bail};
use std::env;
use std::path::{Path, PathBuf};

fn main() -> Result<()> {
    let repo_root = find_repo_root(&env::current_dir()?)?;
    let mut arguments = env::args().skip(1);
    let command = arguments.next().context(
        "usage: cargo run -p xtask -- generate [--check] | regen [--check] | archive --profile debug|release",
    )?;
    match command.as_str() {
        "generate" | "regen" => {
            let check = match arguments.next().as_deref() {
                None => false,
                Some("--check") => true,
                Some(other) => bail!("unknown generate option: {other}"),
            };
            if let Some(extra) = arguments.next() {
                bail!("unexpected argument: {extra}");
            }
            codegen::run(&repo_root, check)
        }
        "archive" => {
            if arguments.next().as_deref() != Some("--profile") {
                bail!("archive requires --profile debug|release");
            }
            let profile = arguments
                .next()
                .context("archive requires --profile debug|release")?;
            if let Some(extra) = arguments.next() {
                bail!("unexpected argument: {extra}");
            }
            codegen::archive(&repo_root, &profile)
        }
        other => bail!("unknown xtask command: {other}"),
    }
}

fn find_repo_root(start: &Path) -> Result<PathBuf> {
    for candidate in start.ancestors() {
        if candidate.join("rust/Cargo.toml").is_file()
            && candidate.join("rust/ffi-contract/abi-v1.json").is_file()
        {
            return Ok(candidate.to_owned());
        }
    }
    bail!("could not locate repository root from {}", start.display())
}
