use anyhow::Result;

#[derive(Debug, Clone)]
pub struct NetInterface {
    pub name: String,
    pub is_wireless: bool,
    pub is_up: bool,
}

// ---------------------------------------------------------------------------
// Real implementation
// ---------------------------------------------------------------------------
#[cfg(not(feature = "dry-run"))]
pub fn list_interfaces() -> Result<Vec<NetInterface>> {
    use std::fs;

    let mut ifaces = Vec::new();
    for entry in fs::read_dir("/sys/class/net")? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();
        if name == "lo" {
            continue;
        }

        let is_wireless = entry.path().join("wireless").exists();

        let operstate = fs::read_to_string(entry.path().join("operstate"))
            .unwrap_or_default()
            .trim()
            .to_string();
        let is_up = operstate == "up";

        ifaces.push(NetInterface {
            name,
            is_wireless,
            is_up,
        });
    }
    ifaces.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(ifaces)
}

#[cfg(not(feature = "dry-run"))]
pub fn check_connectivity() -> bool {
    use std::process::Command;
    Command::new("ping")
        .args(["-c", "1", "-W", "3", "1.1.1.1"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

#[cfg(not(feature = "dry-run"))]
pub fn dhcp_up(interface: &str) -> Result<()> {
    use std::process::Command;
    let status = Command::new("udhcpc")
        .args(["-i", interface, "-n", "-q"])
        .status()?;
    if !status.success() {
        anyhow::bail!("DHCP on {interface} failed");
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Dry-run mocks
// ---------------------------------------------------------------------------
#[cfg(feature = "dry-run")]
pub fn list_interfaces() -> Result<Vec<NetInterface>> {
    Ok(vec![
        NetInterface {
            name: "eth0".into(),
            is_wireless: false,
            is_up: true,
        },
        NetInterface {
            name: "wlan0".into(),
            is_wireless: true,
            is_up: false,
        },
    ])
}

#[cfg(feature = "dry-run")]
pub fn check_connectivity() -> bool {
    true
}

#[cfg(feature = "dry-run")]
pub fn dhcp_up(_interface: &str) -> Result<()> {
    std::thread::sleep(std::time::Duration::from_millis(400));
    Ok(())
}
