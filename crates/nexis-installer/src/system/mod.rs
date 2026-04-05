pub mod bootloader;
pub mod crypt;
pub mod disk;
pub mod fs;
pub mod install;
pub mod network;

use anyhow::Result;

/// Reboot the machine.
pub fn reboot() -> Result<()> {
    crate::util::cmd::run("reboot", &[])?;
    Ok(())
}
