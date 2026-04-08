pub mod bootloader;
pub mod crypt;
pub mod disk;
pub mod fs;
pub mod install;
pub mod network;

use anyhow::Result;

/// Reboot the machine. Under dry-run this just prints and exits.
#[cfg(not(feature = "dry-run"))]
pub fn reboot() -> Result<()> {
    use std::process::Command;
    Command::new("reboot").status()?;
    Ok(())
}

#[cfg(feature = "dry-run")]
pub fn reboot() -> Result<()> {
    // Restore terminal so the message is visible.
    let _ = crossterm::terminal::disable_raw_mode();
    let _ = crossterm::execute!(std::io::stdout(), crossterm::terminal::LeaveAlternateScreen);
    eprintln!("[dry-run] reboot() called — exiting instead.");
    std::process::exit(0);
}
