use anyhow::{Context, Result};

use crate::util::cmd;

const LUKS_MAPPER_NAME: &str = "nexis-root";

/// Format a partition with LUKS2 encryption.
pub fn luks_format(device: &str, passphrase: &str) -> Result<()> {
    cmd::run_with_stdin(
        "cryptsetup",
        &[
            "luksFormat",
            "--type",
            "luks2",
            "--cipher",
            "aes-xts-plain64",
            "--key-size",
            "512",
            "--hash",
            "sha256",
            "--iter-time",
            "5000",
            "--batch-mode",
            device,
        ],
        passphrase,
    )
    .context("failed to format LUKS partition")?;
    Ok(())
}

/// Open a LUKS partition.
pub fn luks_open(device: &str, passphrase: &str) -> Result<String> {
    cmd::run_with_stdin(
        "cryptsetup",
        &["open", "--type", "luks", device, LUKS_MAPPER_NAME],
        passphrase,
    )
    .context("failed to open LUKS partition")?;
    Ok(format!("/dev/mapper/{LUKS_MAPPER_NAME}"))
}

/// Close a LUKS partition.
pub fn luks_close() -> Result<()> {
    cmd::run("cryptsetup", &["close", LUKS_MAPPER_NAME])?;
    Ok(())
}
