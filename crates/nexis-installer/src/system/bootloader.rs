use anyhow::{Context, Result};

use crate::util::cmd;

const MOUNT_ROOT: &str = "/mnt/nexis";

/// Install GRUB for EFI boot.
pub fn install_grub_efi() -> Result<()> {
    let efi_dir = format!("{MOUNT_ROOT}/boot/efi");
    std::fs::create_dir_all(&efi_dir)?;

    cmd::run(
        "grub-install",
        &[
            "--target=x86_64-efi",
            "--efi-directory=/boot/efi",
            "--bootloader-id=NexisOS",
            &format!("--root-directory={MOUNT_ROOT}"),
        ],
    )
    .context("failed to install GRUB EFI")?;

    generate_grub_config()?;
    Ok(())
}

/// Install GRUB for legacy BIOS boot.
pub fn install_grub_bios(device: &str) -> Result<()> {
    cmd::run(
        "grub-install",
        &[
            "--target=i386-pc",
            &format!("--root-directory={MOUNT_ROOT}"),
            device,
        ],
    )
    .context("failed to install GRUB BIOS")?;

    generate_grub_config()?;
    Ok(())
}

fn generate_grub_config() -> Result<()> {
    let grub_dir = format!("{MOUNT_ROOT}/boot/grub");
    std::fs::create_dir_all(&grub_dir)?;

    cmd::run(
        "chroot",
        &[MOUNT_ROOT, "grub-mkconfig", "-o", "/boot/grub/grub.cfg"],
    )
    .context("failed to generate grub.cfg")?;

    Ok(())
}

/// Detect if we booted via EFI.
pub fn is_efi() -> bool {
    std::path::Path::new("/sys/firmware/efi").exists()
}
