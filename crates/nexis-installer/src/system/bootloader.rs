use anyhow::{Context, Result};

#[cfg(not(feature = "dry-run"))]
use crate::util::cmd;

const MOUNT_ROOT: &str = "/mnt/nexis";

/// Detect if we booted via EFI.
pub fn is_efi() -> bool {
    #[cfg(not(feature = "dry-run"))]
    {
        std::path::Path::new("/sys/firmware/efi").exists()
    }
    #[cfg(feature = "dry-run")]
    {
        true
    }
}

// ---------------------------------------------------------------------------
// Real implementation
// ---------------------------------------------------------------------------

/// Install GRUB for EFI boot.
#[cfg(not(feature = "dry-run"))]
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
#[cfg(not(feature = "dry-run"))]
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

#[cfg(not(feature = "dry-run"))]
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

// ---------------------------------------------------------------------------
// Dry-run mocks
// ---------------------------------------------------------------------------

#[cfg(feature = "dry-run")]
pub fn install_grub_efi() -> Result<()> {
    eprintln!("[dry-run] grub-install --target=x86_64-efi --bootloader-id=NexisOS");
    eprintln!("[dry-run] grub-mkconfig -o /boot/grub/grub.cfg");
    Ok(())
}

#[cfg(feature = "dry-run")]
pub fn install_grub_bios(device: &str) -> Result<()> {
    eprintln!("[dry-run] grub-install --target=i386-pc {device}");
    eprintln!("[dry-run] grub-mkconfig -o /boot/grub/grub.cfg");
    Ok(())
}
