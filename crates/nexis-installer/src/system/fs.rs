use anyhow::{bail, Context, Result};

use crate::util::cmd;

/// Supported root filesystem types.
pub const FILESYSTEMS: &[(&str, &str)] = &[
    ("ext4", "Ext4 — mature, reliable, widely supported"),
    ("btrfs", "Btrfs — CoW, snapshots, compression"),
    ("xfs", "XFS — high performance, good for large files"),
    ("f2fs", "F2FS — optimized for flash / NVMe"),
];

/// Format a partition with the chosen filesystem.
pub fn mkfs(device: &str, fs_type: &str, label: &str) -> Result<()> {
    match fs_type {
        "ext4" => {
            cmd::run("mkfs.ext4", &["-L", label, "-F", device])?;
        }
        "btrfs" => {
            cmd::run("mkfs.btrfs", &["-L", label, "-f", device])?;
        }
        "xfs" => {
            cmd::run("mkfs.xfs", &["-L", label, "-f", device])?;
        }
        "f2fs" => {
            cmd::run("mkfs.f2fs", &["-l", label, "-f", device])?;
        }
        _ => bail!("unsupported filesystem: {fs_type}"),
    }
    Ok(())
}

/// Format the EFI system partition.
pub fn mkfs_efi(device: &str) -> Result<()> {
    cmd::run("mkfs.fat", &["-F", "32", "-n", "EFI", device])
        .context("failed to format EFI partition")?;
    Ok(())
}

/// Create and enable swap.
pub fn mkswap(device: &str) -> Result<()> {
    cmd::run("mkswap", &["-L", "swap", device])?;
    cmd::run("swapon", &[device])?;
    Ok(())
}

/// Mount a filesystem.
pub fn mount(device: &str, mountpoint: &str) -> Result<()> {
    std::fs::create_dir_all(mountpoint)
        .with_context(|| format!("failed to create {mountpoint}"))?;
    cmd::run("mount", &[device, mountpoint])?;
    Ok(())
}

/// Unmount a filesystem.
pub fn umount(mountpoint: &str) -> Result<()> {
    cmd::run("umount", &["-R", mountpoint])?;
    Ok(())
}
