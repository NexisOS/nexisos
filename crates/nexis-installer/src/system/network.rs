use anyhow::{Context, Result};

use crate::util::cmd;

#[derive(Debug, Clone)]
pub struct NetInterface {
    pub name: String,
    pub is_wireless: bool,
    pub is_up: bool,
    pub mac: String,
}

/// List network interfaces (excluding loopback).
pub fn list_interfaces() -> Result<Vec<NetInterface>> {
    let entries =
        std::fs::read_dir("/sys/class/net").context("failed to read /sys/class/net")?;

    let mut ifaces = Vec::new();
    for entry in entries {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();
        if name == "lo" {
            continue;
        }

        let is_wireless = entry.path().join("wireless").exists();
        let is_up = std::fs::read_to_string(entry.path().join("operstate"))
            .map(|s| s.trim() == "up")
            .unwrap_or(false);
        let mac = std::fs::read_to_string(entry.path().join("address"))
            .map(|s| s.trim().to_string())
            .unwrap_or_default();

        ifaces.push(NetInterface {
            name,
            is_wireless,
            is_up,
            mac,
        });
    }

    Ok(ifaces)
}

/// Bring up an interface with DHCP via busybox udhcpc.
pub fn dhcp_up(iface: &str) -> Result<()> {
    cmd::run("ip", &["link", "set", iface, "up"])?;
    cmd::run("udhcpc", &["-i", iface, "-q", "-n"])?;
    Ok(())
}

/// Scan for wifi networks (requires wpa_supplicant or iw).
pub fn wifi_scan(iface: &str) -> Result<Vec<String>> {
    let raw = cmd::run_stdout("iw", &["dev", iface, "scan", "ap-force"])?;
    let ssids: Vec<String> = raw
        .lines()
        .filter_map(|line| {
            let trimmed = line.trim();
            trimmed
                .strip_prefix("SSID: ")
                .map(|s| s.to_string())
        })
        .filter(|s| !s.is_empty())
        .collect();
    Ok(ssids)
}

/// Connect to a wifi network.
pub fn wifi_connect(iface: &str, ssid: &str, password: &str) -> Result<()> {
    let conf = format!(
        "network={{\n  ssid=\"{ssid}\"\n  psk=\"{password}\"\n}}\n"
    );
    let conf_path = "/tmp/wpa_supplicant.conf";
    std::fs::write(conf_path, &conf)?;
    cmd::run(
        "wpa_supplicant",
        &["-B", "-i", iface, "-c", conf_path],
    )?;
    dhcp_up(iface)?;
    Ok(())
}

/// Check if we have internet connectivity.
pub fn check_connectivity() -> bool {
    cmd::run("ping", &["-c", "1", "-W", "3", "1.1.1.1"]).is_ok()
}
