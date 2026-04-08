use anyhow::Result;

use crate::app::InstallConfig;

/// Progress callback: (current_step, total_steps, description).
pub type ProgressCb<'a> = dyn FnMut(usize, usize, &str) + 'a;

// ---------------------------------------------------------------------------
// Real implementation
// ---------------------------------------------------------------------------
#[cfg(not(feature = "dry-run"))]
pub fn run_install(config: &InstallConfig, progress: &mut ProgressCb<'_>) -> Result<()> {
    let total = 8;

    progress(1, total, "Partitioning disk");
    partition_disk(config)?;

    progress(2, total, "Formatting filesystems");
    format_filesystems(config)?;

    progress(3, total, "Mounting target");
    mount_target(config)?;

    progress(4, total, "Installing base system");
    install_base(config)?;

    progress(5, total, "Configuring system");
    configure_system(config)?;

    progress(6, total, "Setting up users");
    setup_users(config)?;

    progress(7, total, "Installing bootloader");
    install_bootloader(config)?;

    progress(8, total, "Finalizing");
    finalize(config)?;

    Ok(())
}

#[cfg(not(feature = "dry-run"))]
fn partition_disk(_config: &InstallConfig) -> Result<()> {
    // TODO: real partitioning via sgdisk / sfdisk
    todo!("real partition_disk")
}

#[cfg(not(feature = "dry-run"))]
fn format_filesystems(_config: &InstallConfig) -> Result<()> {
    todo!("real format_filesystems")
}

#[cfg(not(feature = "dry-run"))]
fn mount_target(_config: &InstallConfig) -> Result<()> {
    todo!("real mount_target")
}

#[cfg(not(feature = "dry-run"))]
fn install_base(_config: &InstallConfig) -> Result<()> {
    todo!("real install_base")
}

#[cfg(not(feature = "dry-run"))]
fn configure_system(_config: &InstallConfig) -> Result<()> {
    todo!("real configure_system")
}

#[cfg(not(feature = "dry-run"))]
fn setup_users(_config: &InstallConfig) -> Result<()> {
    todo!("real setup_users")
}

#[cfg(not(feature = "dry-run"))]
fn install_bootloader(_config: &InstallConfig) -> Result<()> {
    todo!("real install_bootloader")
}

#[cfg(not(feature = "dry-run"))]
fn finalize(_config: &InstallConfig) -> Result<()> {
    todo!("real finalize")
}

// ---------------------------------------------------------------------------
// Dry-run mock — simulates each stage with a short sleep
// ---------------------------------------------------------------------------
#[cfg(feature = "dry-run")]
pub fn run_install(config: &InstallConfig, progress: &mut ProgressCb<'_>) -> Result<()> {
    use std::thread::sleep;
    use std::time::Duration;

    let device = config
        .disk
        .as_ref()
        .map(|d| d.device.as_str())
        .unwrap_or("(none)");

    let stages: &[&str] = &[
        "Partitioning disk",
        "Formatting filesystems",
        "Mounting target",
        "Installing base system",
        "Configuring system",
        "Setting up users",
        "Installing bootloader",
        "Finalizing",
    ];

    let total = stages.len();

    for (i, desc) in stages.iter().enumerate() {
        let label = if i == 0 {
            format!("{desc} ({device})")
        } else {
            desc.to_string()
        };
        progress(i + 1, total, &label);
        // Simulate work — longer for "Installing base system".
        let ms = if i == 3 { 1200 } else { 350 };
        sleep(Duration::from_millis(ms));
    }

    Ok(())
}
