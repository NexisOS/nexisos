use anyhow::{Context, Result};
use serde::Deserialize;

use crate::util::cmd;

#[derive(Debug, Clone)]
pub struct BlockDevice {
    pub name: String,
    pub path: String,
    pub size_bytes: u64,
    pub model: String,
    pub removable: bool,
    pub ro: bool,
}

impl BlockDevice {
    pub fn size_display(&self) -> String {
        let gb = self.size_bytes as f64 / 1_073_741_824.0;
        if gb >= 1.0 {
            format!("{:.1} GiB", gb)
        } else {
            format!("{} MiB", self.size_bytes / 1_048_576)
        }
    }
}

#[derive(Deserialize)]
struct LsblkJson {
    blockdevices: Vec<LsblkDevice>,
}

#[derive(Deserialize)]
struct LsblkDevice {
    name: String,
    path: String,
    size: u64,
    model: Option<String>,
    rm: bool,
    ro: bool,
    #[serde(rename = "type")]
    dtype: String,
}

/// List all block devices suitable for installation.
pub fn list_disks() -> Result<Vec<BlockDevice>> {
    let raw = cmd::run_stdout(
        "lsblk",
        &["-J", "-b", "-o", "NAME,PATH,SIZE,MODEL,RM,RO,TYPE"],
    )
    .context("failed to list block devices")?;

    let parsed: LsblkJson =
        serde_json::from_str(&raw).context("failed to parse lsblk output")?;

    let disks = parsed
        .blockdevices
        .into_iter()
        .filter(|d| d.dtype == "disk" && !d.ro)
        .map(|d| BlockDevice {
            name: d.name,
            path: d.path,
            size_bytes: d.size,
            model: d.model.unwrap_or_default(),
            removable: d.rm,
            ro: d.ro,
        })
        .collect();

    Ok(disks)
}

/// Wipe partition table.
pub fn wipe_disk(device: &str) -> Result<()> {
    cmd::run("wipefs", &["--all", device])?;
    cmd::run("sgdisk", &["--zap-all", device])?;
    Ok(())
}

/// Create a GPT partition layout with EFI + optional swap + root.
pub fn partition_auto(device: &str, swap_size_mb: u64, use_swap: bool) -> Result<Vec<String>> {
    wipe_disk(device)?;

    // Build sfdisk script.
    let mut script = String::from("label: gpt\n");

    // EFI system partition: 512 MiB.
    script.push_str("size=512M, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=EFI\n");

    if use_swap && swap_size_mb > 0 {
        script.push_str(&format!(
            "size={}M, type=0657FD6D-A4AB-43C4-84E5-0933C84B4F4F, name=swap\n",
            swap_size_mb
        ));
    }

    // Root: rest of the disk.
    script.push_str("type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name=root\n");

    cmd::run_with_stdin("sfdisk", &[device], &script)?;

    // Re-read partition table.
    let _ = cmd::run("partprobe", &[device]);

    // Return partition paths.
    let mut parts = Vec::new();
    let suffix = if device.ends_with(|c: char| c.is_ascii_digit()) {
        "p"
    } else {
        ""
    };
    parts.push(format!("{device}{suffix}1")); // EFI
    if use_swap {
        parts.push(format!("{device}{suffix}2")); // swap
        parts.push(format!("{device}{suffix}3")); // root
    } else {
        parts.push(format!("{device}{suffix}2")); // root (no swap)
    }

    Ok(parts)
}
