use anyhow::Result;

#[derive(Debug, Clone)]
pub struct BlockDevice {
    pub path: String,
    pub model: String,
    pub size_bytes: u64,
}

impl BlockDevice {
    pub fn size_display(&self) -> String {
        const GIB: u64 = 1024 * 1024 * 1024;
        const MIB: u64 = 1024 * 1024;
        if self.size_bytes >= GIB {
            format!("{:.1} GiB", self.size_bytes as f64 / GIB as f64)
        } else {
            format!("{} MiB", self.size_bytes / MIB)
        }
    }
}

// ---------------------------------------------------------------------------
// Real implementation
// ---------------------------------------------------------------------------
#[cfg(not(feature = "dry-run"))]
pub fn list_disks() -> Result<Vec<BlockDevice>> {
    use std::fs;

    let mut devices = Vec::new();
    for entry in fs::read_dir("/sys/block")? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();

        // Skip loop, ram, and dm devices.
        if name.starts_with("loop")
            || name.starts_with("ram")
            || name.starts_with("dm-")
            || name.starts_with("sr")
        {
            continue;
        }

        let dev_path = format!("/dev/{name}");
        let size_bytes = fs::read_to_string(format!("/sys/block/{name}/size"))
            .unwrap_or_default()
            .trim()
            .parse::<u64>()
            .unwrap_or(0)
            * 512;

        if size_bytes == 0 {
            continue;
        }

        let model = fs::read_to_string(format!("/sys/block/{name}/device/model"))
            .unwrap_or_default()
            .trim()
            .to_string();

        devices.push(BlockDevice {
            path: dev_path,
            model,
            size_bytes,
        });
    }

    devices.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(devices)
}

// ---------------------------------------------------------------------------
// Dry-run mock
// ---------------------------------------------------------------------------
#[cfg(feature = "dry-run")]
pub fn list_disks() -> Result<Vec<BlockDevice>> {
    Ok(vec![
        BlockDevice {
            path: "/dev/sda".into(),
            model: "NEXIS VDISK 50G".into(),
            size_bytes: 50 * 1024 * 1024 * 1024,
        },
        BlockDevice {
            path: "/dev/sdb".into(),
            model: "Fake USB Stick".into(),
            size_bytes: 16 * 1024 * 1024 * 1024,
        },
        BlockDevice {
            path: "/dev/nvme0n1".into(),
            model: "NEXIS NVMe 256G".into(),
            size_bytes: 256 * 1024 * 1024 * 1024,
        },
    ])
}
