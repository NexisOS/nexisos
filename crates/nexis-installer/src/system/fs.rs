/// Supported root filesystems: (id, human description).
pub const FILESYSTEMS: &[(&str, &str)] = &[
    ("ext4",  "ext4  — mature, journaled, widely supported"),
    ("btrfs", "btrfs — CoW, snapshots, compression"),
    ("xfs",   "xfs   — high-performance, scalable"),
    ("f2fs",  "f2fs  — flash-friendly, good for SSDs"),
];

// ---------------------------------------------------------------------------
// Real helpers (called during actual install, not from the TUI steps directly)
// ---------------------------------------------------------------------------
#[cfg(not(feature = "dry-run"))]
pub fn mkfs(device: &str, fs_type: &str, label: &str) -> anyhow::Result<()> {
    use std::process::Command;
    let status = match fs_type {
        "ext4" => Command::new("mkfs.ext4")
            .args(["-L", label, device])
            .status()?,
        "btrfs" => Command::new("mkfs.btrfs")
            .args(["-f", "-L", label, device])
            .status()?,
        "xfs" => Command::new("mkfs.xfs")
            .args(["-f", "-L", label, device])
            .status()?,
        "f2fs" => Command::new("mkfs.f2fs")
            .args(["-f", "-l", label, device])
            .status()?,
        other => anyhow::bail!("Unsupported filesystem: {other}"),
    };
    if !status.success() {
        anyhow::bail!("mkfs.{fs_type} failed on {device}");
    }
    Ok(())
}

#[cfg(feature = "dry-run")]
pub fn mkfs(device: &str, fs_type: &str, label: &str) -> anyhow::Result<()> {
    eprintln!("[dry-run] mkfs.{fs_type} -L {label} {device}");
    Ok(())
}
