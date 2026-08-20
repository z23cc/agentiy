use crate::identity::{self, BuildIdentity, MINIMUM_MACOS, TARGET};
use anyhow::{Context, Result, bail};
use camino::Utf8PathBuf;
use serde::Serialize;
use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use uniffi_bindgen::bindings::{GenerateOptions, TargetLanguage};

const PROFILE: &str = "debug";

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ArchiveManifest<'a> {
    schema_version: u32,
    target: &'a str,
    profile: &'a str,
    abi_epoch: u32,
    build_fingerprint: &'a str,
    binding_checksum: &'a str,
    archive_sha256: &'a str,
}

struct GeneratedArtifact {
    relative_path: &'static str,
    bytes: Vec<u8>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct GeneratedManifest<'a> {
    schema_version: u32,
    target: &'a str,
    profile: &'a str,
    abi_epoch: u32,
    build_fingerprint: &'a str,
    binding_checksum: &'a str,
    fingerprint_inputs: &'a identity::FingerprintInputs,
    archive_sha256: &'a str,
    expected_exports: Vec<String>,
    artifact_sha256: BTreeMap<&'static str, String>,
}

pub fn run(repo_root: &Path, check: bool) -> Result<()> {
    let target_dir = controlled_target_dir(repo_root)?;
    let build_identity = identity::calculate(repo_root, PROFILE)?;
    let release_identity = identity::calculate(repo_root, "release")?;
    let archive = build_staticlib(repo_root, &target_dir, PROFILE, &build_identity)?;
    let staged_archive = stage_archive(repo_root, PROFILE, &archive, &build_identity, false)?;
    let archive_sha256 = identity::digest_file(&staged_archive)?;

    let stage = repo_root.join(".build/agentry-rust/codegen-stage");
    if stage.exists() {
        fs::remove_dir_all(&stage)?;
    }
    fs::create_dir_all(&stage)?;
    generate_uniffi(repo_root, &stage, &staged_archive)?;

    let swift = fs::read(stage.join("AgentryCore.swift"))
        .context("UniFFI did not generate AgentryCore.swift")?;
    let header = fs::read(stage.join("AgentryCoreFFI.h"))
        .context("UniFFI did not generate AgentryCoreFFI.h")?;
    let mut artifacts = vec![
        GeneratedArtifact {
            relative_path: "Sources/AgentryUniFFIRaw/Generated/AgentryCore.swift",
            bytes: swift,
        },
        GeneratedArtifact {
            relative_path: "Sources/CAgentryRustCore/include/AgentryCoreFFI.h",
            bytes: header,
        },
        GeneratedArtifact {
            relative_path: "Sources/CAgentryRustCore/include/module.modulemap",
            bytes: ordinary_module_map().into_bytes(),
        },
        GeneratedArtifact {
            relative_path: "Sources/AgentryUniFFIRaw/Generated/AgentryCoreBindingIdentity.swift",
            bytes: render_swift_identity(&build_identity, &release_identity).into_bytes(),
        },
        GeneratedArtifact {
            relative_path: "rust/crates/ffi/src/generated/contract_identity.rs",
            bytes: render_rust_identity(&build_identity).into_bytes(),
        },
    ];

    for artifact in &mut artifacts {
        artifact.bytes = normalize_generated_text(&artifact.bytes);
    }

    let artifact_sha256 = artifacts
        .iter()
        .map(|artifact| {
            (
                artifact.relative_path,
                identity::digest_bytes(&artifact.bytes),
            )
        })
        .collect();
    let expected_exports = read_exports(repo_root)?;
    let manifest = GeneratedManifest {
        schema_version: 1,
        target: TARGET,
        profile: PROFILE,
        abi_epoch: build_identity.inputs.abi_epoch,
        build_fingerprint: &build_identity.build_fingerprint,
        binding_checksum: &build_identity.binding_checksum,
        fingerprint_inputs: &build_identity.inputs,
        archive_sha256: &archive_sha256,
        expected_exports,
        artifact_sha256,
    };
    let manifest_bytes = serde_json::to_vec_pretty(&manifest)?;
    artifacts.push(GeneratedArtifact {
        relative_path: "rust/ffi-contract/generated-manifest.json",
        bytes: normalize_generated_text(&manifest_bytes),
    });

    if check {
        check_artifacts(repo_root, &artifacts)?;
        println!(
            "generated artifacts match (fingerprint {}, archive {})",
            build_identity.build_fingerprint,
            staged_archive.display()
        );
    } else {
        write_artifacts(repo_root, &artifacts)?;
        println!(
            "generated {} deterministic artifacts (fingerprint {}, archive {})",
            artifacts.len(),
            build_identity.build_fingerprint,
            staged_archive.display()
        );
    }
    Ok(())
}

pub fn archive(repo_root: &Path, profile: &str) -> Result<()> {
    let target_dir = controlled_target_dir(repo_root)?;
    let build_identity = identity::calculate(repo_root, profile)?;
    let archive = build_staticlib(repo_root, &target_dir, profile, &build_identity)?;
    let staged = stage_archive(repo_root, profile, &archive, &build_identity, true)?;
    println!(
        "{} {} {}",
        staged.display(),
        build_identity.build_fingerprint,
        identity::digest_file(&staged)?
    );
    Ok(())
}

fn controlled_target_dir(repo_root: &Path) -> Result<PathBuf> {
    let expected = repo_root.join(".build/cargo");
    let path = env::var_os("CARGO_TARGET_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| expected.clone());
    if path != expected {
        bail!(
            "CARGO_TARGET_DIR must be the conductor-controlled path {}; run `make dev-cargo-archive PROFILE=debug`",
            expected.display()
        );
    }
    fs::create_dir_all(&path)?;
    Ok(path)
}

fn build_staticlib(
    repo_root: &Path,
    target_dir: &Path,
    profile: &str,
    build_identity: &BuildIdentity,
) -> Result<PathBuf> {
    let mut command = Command::new("cargo");
    command
        .args([
            "build",
            "--manifest-path",
            "rust/Cargo.toml",
            "--target",
            TARGET,
            "-p",
            "agentry-ffi",
            "--locked",
        ])
        .current_dir(repo_root)
        .env("CARGO_TARGET_DIR", target_dir)
        .env("CARGO_INCREMENTAL", "0")
        .env("MACOSX_DEPLOYMENT_TARGET", MINIMUM_MACOS)
        .env(
            "AGENTRY_CORE_BUILD_FINGERPRINT",
            &build_identity.build_fingerprint,
        )
        .env(
            "AGENTRY_CORE_BINDING_CHECKSUM",
            &build_identity.binding_checksum,
        );
    if profile == "release" {
        command.arg("--release");
    }
    let status = command.status().context("build agentry-ffi staticlib")?;
    if !status.success() {
        bail!("agentry-ffi staticlib build failed with {status}");
    }
    let profile_dir = if profile == "release" {
        "release"
    } else {
        "debug"
    };
    let archive = target_dir
        .join(TARGET)
        .join(profile_dir)
        .join("libagentry_ffi.a");
    if !archive.is_file() {
        bail!("staticlib was not produced at {}", archive.display());
    }
    Ok(archive)
}

fn stage_archive(
    repo_root: &Path,
    profile: &str,
    source: &Path,
    build_identity: &BuildIdentity,
    publish: bool,
) -> Result<PathBuf> {
    let root = repo_root.join(".build/agentry-rust");
    let process = std::process::id();
    let temporary = root.join(format!(".archive-stage-{profile}-{process}"));
    if temporary.exists() {
        fs::remove_dir_all(&temporary)?;
    }
    fs::create_dir_all(&temporary)?;
    let destination = write_archive_bundle(&temporary, profile, source, build_identity)?;
    if !publish {
        return Ok(destination);
    }

    let archive_sha256 = identity::digest_file(&destination)?;
    let generation_name = format!(
        "{}-{}",
        build_identity.build_fingerprint,
        &archive_sha256[..16]
    );
    let generation = root
        .join("generations")
        .join(TARGET)
        .join(profile)
        .join(generation_name);
    if generation.exists() {
        verify_archive_bundle(&generation, profile, build_identity, &archive_sha256)?;
        fs::remove_dir_all(&temporary)?;
    } else {
        fs::create_dir_all(
            generation
                .parent()
                .context("archive generation has no parent")?,
        )?;
        fs::rename(&temporary, &generation)?;
    }

    atomic_symlink(
        &generation,
        &root.join(TARGET).join(profile),
        "profile archive",
    )?;
    atomic_symlink(&generation, &root.join("current"), "current archive")?;
    Ok(generation.join("libagentry_ffi.a"))
}

fn write_archive_bundle(
    directory: &Path,
    profile: &str,
    source: &Path,
    build_identity: &BuildIdentity,
) -> Result<PathBuf> {
    let destination = directory.join("libagentry_ffi.a");
    fs::copy(source, &destination)?;
    let archive_sha256 = identity::digest_file(&destination)?;
    let manifest = ArchiveManifest {
        schema_version: 1,
        target: TARGET,
        profile,
        abi_epoch: build_identity.inputs.abi_epoch,
        build_fingerprint: &build_identity.build_fingerprint,
        binding_checksum: &build_identity.binding_checksum,
        archive_sha256: &archive_sha256,
    };
    let mut manifest_bytes = serde_json::to_vec_pretty(&manifest)?;
    manifest_bytes.push(b'\n');
    fs::write(directory.join("artifact-manifest.json"), manifest_bytes)?;
    fs::write(
        directory.join("AgentryRustArchiveReady.h"),
        format!(
            "// @generated by xtask archive; do not edit.\n#define AGENTRY_RUST_ARCHIVE_ABI_EPOCH {}\n",
            build_identity.inputs.abi_epoch
        ),
    )?;
    Ok(destination)
}

fn verify_archive_bundle(
    directory: &Path,
    profile: &str,
    build_identity: &BuildIdentity,
    archive_sha256: &str,
) -> Result<()> {
    let existing_archive = directory.join("libagentry_ffi.a");
    if identity::digest_file(&existing_archive)? != archive_sha256 {
        bail!(
            "immutable archive generation was modified: {}",
            directory.display()
        );
    }
    let manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(directory.join("artifact-manifest.json"))?)?;
    if manifest["profile"] != profile
        || manifest["buildFingerprint"] != build_identity.build_fingerprint
        || manifest["bindingChecksum"] != build_identity.binding_checksum
        || manifest["archiveSha256"] != archive_sha256
    {
        bail!(
            "immutable archive generation metadata was modified: {}",
            directory.display()
        );
    }
    Ok(())
}

fn atomic_symlink(source: &Path, destination: &Path, label: &str) -> Result<()> {
    use std::os::unix::fs::symlink;

    let parent = destination
        .parent()
        .context("archive symlink has no parent directory")?;
    fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(
        ".{}-{}.tmp",
        destination
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("archive"),
        std::process::id()
    ));
    if fs::symlink_metadata(&temporary).is_ok() {
        fs::remove_file(&temporary)?;
    }
    symlink(source, &temporary).with_context(|| format!("create {label} symlink"))?;

    if let Ok(metadata) = fs::symlink_metadata(destination)
        && metadata.file_type().is_dir()
        && !metadata.file_type().is_symlink()
    {
        fs::remove_dir_all(destination)?;
    }
    fs::rename(&temporary, destination).with_context(|| format!("publish {label} symlink"))?;
    Ok(())
}

fn generate_uniffi(repo_root: &Path, stage: &Path, archive: &Path) -> Result<()> {
    let source = Utf8PathBuf::from_path_buf(archive.to_owned())
        .map_err(|path| anyhow::anyhow!("non-UTF-8 archive path: {}", path.display()))?;
    let out_dir = Utf8PathBuf::from_path_buf(stage.to_owned())
        .map_err(|path| anyhow::anyhow!("non-UTF-8 stage path: {}", path.display()))?;
    let previous = env::current_dir()?;
    env::set_current_dir(repo_root.join("rust"))?;
    let result = uniffi_bindgen::bindings::generate(GenerateOptions {
        languages: vec![TargetLanguage::Swift],
        source,
        out_dir,
        config_override: None,
        format: false,
        crate_filter: Some("agentry_ffi".to_owned()),
        metadata_no_deps: true,
    });
    env::set_current_dir(previous)?;
    result.context("generate Swift bindings from staticlib metadata")
}

fn normalize_generated_text(bytes: &[u8]) -> Vec<u8> {
    let mut lines: Vec<&[u8]> = bytes
        .split(|byte| *byte == b'\n')
        .map(|line| {
            let end = line
                .iter()
                .rposition(|byte| !byte.is_ascii_whitespace())
                .map_or(0, |index| index + 1);
            &line[..end]
        })
        .collect();
    while lines.last().is_some_and(|line| line.is_empty()) {
        lines.pop();
    }

    let mut normalized = Vec::with_capacity(bytes.len() + 1);
    for line in lines {
        normalized.extend_from_slice(line);
        normalized.push(b'\n');
    }
    if normalized.is_empty() {
        normalized.push(b'\n');
    }
    normalized
}

fn ordinary_module_map() -> String {
    "module AgentryCoreFFI {\n    header \"AgentryCoreFFI.h\"\n    export *\n}\n".to_owned()
}

fn render_rust_identity(identity: &BuildIdentity) -> String {
    format!(
        r#"// @generated by `cargo run -p xtask -- generate`; do not edit.

pub const ABI_EPOCH: u32 = {};
pub const PAYLOAD_SCHEMA_VERSIONS: &[u16] = &[1];
const ZERO_SHA256: &str = "0000000000000000000000000000000000000000000000000000000000000000";
pub const BINDING_CHECKSUM: &str = match option_env!("AGENTRY_CORE_BINDING_CHECKSUM") {{
    Some(value) => value,
    None => ZERO_SHA256,
}};
pub const CORE_BUILD_FINGERPRINT: &str = match option_env!("AGENTRY_CORE_BUILD_FINGERPRINT") {{
    Some(value) => value,
    None => ZERO_SHA256,
}};
"#,
        identity.inputs.abi_epoch
    )
}

fn render_swift_identity(
    debug_identity: &BuildIdentity,
    release_identity: &BuildIdentity,
) -> String {
    format!(
        r#"// @generated by `cargo run -p xtask -- generate`; do not edit.

public enum AgentryCoreBindingIdentity {{
    public static let abiEpoch: UInt32 = {}
    public static let payloadSchemaVersions: [UInt16] = [1]
#if DEBUG
    public static let buildFingerprint = "{}"
#else
    public static let buildFingerprint = "{}"
#endif
    public static let bindingChecksum = "{}"
}}
"#,
        debug_identity.inputs.abi_epoch,
        debug_identity.build_fingerprint,
        release_identity.build_fingerprint,
        debug_identity.binding_checksum
    )
}

fn read_exports(repo_root: &Path) -> Result<Vec<String>> {
    let text = fs::read_to_string(repo_root.join("rust/ffi-contract/exports.txt"))?;
    Ok(text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(str::to_owned)
        .collect())
}

fn check_artifacts(repo_root: &Path, artifacts: &[GeneratedArtifact]) -> Result<()> {
    let mut mismatches = Vec::new();
    for artifact in artifacts {
        let path = repo_root.join(artifact.relative_path);
        match fs::read(&path) {
            Ok(existing) if existing == artifact.bytes => {}
            Ok(_) => mismatches.push(format!("changed: {}", artifact.relative_path)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                mismatches.push(format!("missing: {}", artifact.relative_path));
            }
            Err(error) => return Err(error.into()),
        }
    }
    if !mismatches.is_empty() {
        bail!(
            "generated artifact check failed:\n{}\nrun `cargo run -p xtask -- generate`",
            mismatches.join("\n")
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::normalize_generated_text;

    #[test]
    fn generated_text_has_no_trailing_whitespace_and_one_final_newline() {
        assert_eq!(
            normalize_generated_text(b"first  \r\nsecond\t\n\t\n\n"),
            b"first\nsecond\n"
        );
        assert_eq!(normalize_generated_text(b"first"), b"first\n");
        assert_eq!(normalize_generated_text(b""), b"\n");
    }

    #[test]
    fn generated_text_normalization_is_idempotent() {
        let normalized = normalize_generated_text(b"first  \n\nsecond\t\n\n");
        assert_eq!(normalize_generated_text(&normalized), normalized);
    }
}

fn write_artifacts(repo_root: &Path, artifacts: &[GeneratedArtifact]) -> Result<()> {
    let process = std::process::id();
    for artifact in artifacts {
        let destination = repo_root.join(artifact.relative_path);
        let parent = destination
            .parent()
            .context("generated artifact has no parent directory")?;
        fs::create_dir_all(parent)?;
        let temporary = parent.join(format!(".agentry-generated-{process}.tmp"));
        fs::write(&temporary, &artifact.bytes)?;
        fs::rename(&temporary, &destination)?;
    }
    Ok(())
}
