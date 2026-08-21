use anyhow::{Context, Result, bail};
use serde::Serialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};

pub const TARGET: &str = "aarch64-apple-darwin";
pub const MINIMUM_MACOS: &str = "14.0";

const BUILD_INPUT_PATHS: &[&str] = &[
    ".cargo/config.toml",
    "rust/.cargo/config.toml",
    "rust/Cargo.toml",
    "rust/Cargo.lock",
    "rust/rust-toolchain.toml",
    "rust/ffi-contract/abi-v1.json",
    "rust/ffi-contract/exports.txt",
    "rust/crates",
];
const GENERATED_CONTRACT_IDENTITY: &str = "rust/crates/ffi/src/generated/contract_identity.rs";

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FingerprintInputs {
    pub abi_epoch: u32,
    pub payload_schema_set: Vec<String>,
    pub rust_source_revision: String,
    pub cargo_lock_digest: String,
    pub toolchain_digest: String,
    pub toolchain_channel: String,
    pub feature_set: Vec<String>,
    pub build_profile: String,
    pub target: String,
    pub minimum_macos_version: String,
}

#[derive(Clone, Debug)]
pub struct BuildIdentity {
    pub inputs: FingerprintInputs,
    pub binding_checksum: String,
    pub build_fingerprint: String,
}

pub fn calculate(repo_root: &Path, profile: &str) -> Result<BuildIdentity> {
    if !matches!(profile, "debug" | "release") {
        bail!("profile must be debug or release");
    }
    let rust = repo_root.join("rust");
    let abi_bytes = fs::read(rust.join("ffi-contract/abi-v1.json"))?;
    let abi: Value = serde_json::from_slice(&abi_bytes).context("parse ABI contract")?;
    let abi_epoch = abi["abiEpoch"]
        .as_u64()
        .and_then(|value| u32::try_from(value).ok())
        .context("ABI contract abiEpoch must be a u32")?;
    let schema = abi["envelope"]["schemaVersion"]
        .as_u64()
        .and_then(|value| u16::try_from(value).ok())
        .context("ABI contract envelope schemaVersion must be a u16")?;
    let exports = fs::read(rust.join("ffi-contract/exports.txt"))?;
    let mut binding_bytes = abi_bytes;
    binding_bytes.push(0);
    binding_bytes.extend_from_slice(&exports);
    let binding_checksum = digest_bytes(&binding_bytes);

    let lock = fs::read(rust.join("Cargo.lock"))?;
    let toolchain = fs::read(rust.join("rust-toolchain.toml"))?;
    let toolchain_text = String::from_utf8(toolchain.clone())?;
    let toolchain_channel = toolchain_text
        .lines()
        .find_map(|line| {
            let line = line.trim();
            line.strip_prefix("channel = ")
                .map(|value| value.trim_matches('"').to_owned())
        })
        .context("rust-toolchain.toml must contain a channel")?;

    let inputs = FingerprintInputs {
        abi_epoch,
        payload_schema_set: vec![format!("agentry-envelope-v{schema}")],
        rust_source_revision: source_revision(repo_root)?,
        cargo_lock_digest: digest_bytes(&lock),
        toolchain_digest: digest_bytes(&toolchain),
        toolchain_channel,
        feature_set: Vec::new(),
        build_profile: profile.to_owned(),
        target: TARGET.to_owned(),
        minimum_macos_version: MINIMUM_MACOS.to_owned(),
    };
    let canonical = serde_json::to_vec(&inputs)?;
    let build_fingerprint = digest_bytes(&canonical);
    Ok(BuildIdentity {
        inputs,
        binding_checksum,
        build_fingerprint,
    })
}

pub fn digest_file(path: &Path) -> Result<String> {
    Ok(digest_bytes(&fs::read(path)?))
}

pub fn digest_bytes(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut output = String::with_capacity(64);
    for byte in digest {
        use std::fmt::Write;
        write!(&mut output, "{byte:02x}").expect("writing to String cannot fail");
    }
    output
}

fn source_revision(repo_root: &Path) -> Result<String> {
    // Always the content digest of the Rust build inputs. The earlier
    // clean-tree fast path returned `git:<HEAD>`, which rotated the build
    // fingerprint on EVERY commit (HEAD changes even when no Rust input
    // changed), immediately invalidating the just-committed binding identity.
    // The content form is deterministic, identical for identical inputs
    // regardless of git state, and changes exactly when a build input changes.
    Ok(format!("tree:{}", digest_build_inputs(repo_root)?))
}

fn digest_build_inputs(repo_root: &Path) -> Result<String> {
    let mut files = Vec::new();
    let mut missing = Vec::new();
    for relative in BUILD_INPUT_PATHS {
        let path = repo_root.join(relative);
        if path.is_dir() {
            collect_files(repo_root, &path, &mut files)?;
        } else if path.is_file() {
            files.push(PathBuf::from(relative));
        } else {
            missing.push(PathBuf::from(relative));
        }
    }
    files.sort();
    missing.sort();

    let mut hasher = Sha256::new();
    for relative in missing {
        hasher.update(relative.to_string_lossy().as_bytes());
        hasher.update(b"\0missing\0");
    }
    for relative in files {
        if relative == Path::new(GENERATED_CONTRACT_IDENTITY) {
            continue;
        }
        let bytes = fs::read(repo_root.join(&relative))?;
        hasher.update(relative.to_string_lossy().as_bytes());
        hasher.update([0]);
        hasher.update(Sha256::digest(bytes));
        hasher.update([0]);
    }
    let digest = hasher.finalize();
    let mut output = String::with_capacity(64);
    for byte in digest {
        use std::fmt::Write;
        write!(&mut output, "{byte:02x}").expect("writing to String cannot fail");
    }
    Ok(output)
}

fn collect_files(root: &Path, current: &Path, output: &mut Vec<PathBuf>) -> Result<()> {
    for entry in fs::read_dir(current)? {
        let entry = entry?;
        let path = entry.path();
        if entry.file_type()?.is_dir() {
            collect_files(root, &path, output)?;
        } else if entry.file_type()?.is_file() {
            output.push(path.strip_prefix(root)?.to_owned());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(1);

    struct Fixture {
        root: PathBuf,
    }

    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "agentry-identity-test-{}-{}",
                std::process::id(),
                NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed)
            ));
            let fixture = Self { root };
            fixture.write(
                "rust/Cargo.toml",
                "[workspace]\nmembers = [\"crates/runtime\"]\n",
            );
            fixture.write("rust/Cargo.lock", "version = 4\n");
            fixture.write(
                "rust/rust-toolchain.toml",
                "[toolchain]\nchannel = \"1.85.0\"\n",
            );
            fixture.write(
                "rust/ffi-contract/abi-v1.json",
                r#"{"abiEpoch":1,"envelope":{"schemaVersion":1}}"#,
            );
            fixture.write("rust/ffi-contract/exports.txt", "agentry_core_init\n");
            fixture.write(
                "rust/crates/runtime/Cargo.toml",
                "[package]\nname = \"runtime\"\n",
            );
            fixture.write("rust/crates/runtime/src/lib.rs", "pub fn run() {}\n");
            fixture
        }

        fn write(&self, relative: &str, contents: &str) {
            let path = self.root.join(relative);
            fs::create_dir_all(path.parent().expect("fixture parent")).expect("create fixture");
            fs::write(path, contents).expect("write fixture");
        }

        fn fingerprint(&self, profile: &str) -> String {
            calculate(&self.root, profile)
                .expect("calculate identity")
                .build_fingerprint
        }

        fn assert_change(&self, relative: &str, contents: &str) {
            let before = self.fingerprint("debug");
            self.write(relative, contents);
            assert_ne!(before, self.fingerprint("debug"));
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn workspace_manifest_changes_fingerprint() {
        Fixture::new().assert_change(
            "rust/Cargo.toml",
            "[workspace]\nmembers = [\"crates/runtime\"]\n[profile.release]\nlto = true\n",
        );
    }

    #[test]
    fn crate_manifest_changes_fingerprint() {
        Fixture::new().assert_change(
            "rust/crates/runtime/Cargo.toml",
            "[package]\nname = \"runtime\"\nversion = \"0.1.0\"\n",
        );
    }

    #[test]
    fn cargo_config_changes_fingerprint() {
        Fixture::new().assert_change(
            "rust/.cargo/config.toml",
            "[build]\nrustflags = [\"-Ctarget-cpu=apple-m1\"]\n",
        );
    }

    #[test]
    fn ffi_contract_changes_fingerprint() {
        Fixture::new().assert_change(
            "rust/ffi-contract/exports.txt",
            "agentry_core_init\nagentry_core_shutdown\n",
        );
    }

    #[test]
    fn toolchain_changes_fingerprint() {
        Fixture::new().assert_change(
            "rust/rust-toolchain.toml",
            "[toolchain]\nchannel = \"1.86.0\"\n",
        );
    }

    #[test]
    fn lockfile_changes_fingerprint() {
        Fixture::new().assert_change("rust/Cargo.lock", "version = 4\n# dependency change\n");
    }

    #[test]
    fn rust_source_changes_fingerprint() {
        Fixture::new().assert_change(
            "rust/crates/runtime/src/lib.rs",
            "pub fn run() { loop {} }\n",
        );
    }

    #[test]
    fn build_profile_changes_fingerprint() {
        let fixture = Fixture::new();
        assert_ne!(fixture.fingerprint("debug"), fixture.fingerprint("release"));
    }
}
