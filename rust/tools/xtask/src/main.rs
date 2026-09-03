mod codegen;
mod identity;
mod mcp_catalog;
mod proto_codegen;

use anyhow::{Context, Result, bail};
use std::env;
use std::path::{Path, PathBuf};

fn main() -> Result<()> {
    let repo_root = find_repo_root(&env::current_dir()?)?;
    let mut arguments = env::args().skip(1);
    let command = arguments.next().context(
        "usage: cargo run -p xtask -- generate [--check] | regen [--check] | proto generate|check | mcp-catalog generate|check | archive --profile debug|release",
    )?;
    match command.as_str() {
        // Fast path for schema work: renders only the agent-host-v1 module without the staticlib
        // build. `generate` remains the authoritative all-artifacts path and includes this render.
        "proto" => {
            let mode = arguments
                .next()
                .context("proto requires generate or check")?;
            if let Some(extra) = arguments.next() {
                bail!("unexpected argument: {extra}");
            }
            match mode.as_str() {
                "generate" => codegen::run_proto_only(&repo_root, false),
                "check" => codegen::run_proto_only(&repo_root, true),
                other => bail!("unknown proto mode: {other}"),
            }
        }
        "generate" | "regen" => {
            let check = match arguments.next().as_deref() {
                None => false,
                Some("--check") => true,
                Some(other) => bail!("unknown generate option: {other}"),
            };
            if let Some(extra) = arguments.next() {
                bail!("unexpected argument: {extra}");
            }
            codegen::run(&repo_root, check)?;
            mcp_catalog::run(&repo_root, check)
        }
        "mcp-catalog" => {
            let mode = arguments
                .next()
                .context("mcp-catalog requires generate or check")?;
            if let Some(extra) = arguments.next() {
                bail!("unexpected argument: {extra}");
            }
            match mode.as_str() {
                "generate" => mcp_catalog::run(&repo_root, false),
                "check" => mcp_catalog::run(&repo_root, true),
                other => bail!("unknown mcp-catalog mode: {other}"),
            }
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
