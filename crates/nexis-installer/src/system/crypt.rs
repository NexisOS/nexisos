use anyhow::Result;

#[cfg(not(feature = "dry-run"))]
pub fn luks_format(device: &str, passphrase: &str) -> Result<()> {
    use std::process::{Command, Stdio};
    use std::io::Write;

    let mut child = Command::new("cryptsetup")
        .args(["luksFormat", "--type", "luks2", "--batch-mode", device])
        .stdin(Stdio::piped())
        .spawn()?;

    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(passphrase.as_bytes())?;
    }
    let status = child.wait()?;
    if !status.success() {
        anyhow::bail!("cryptsetup luksFormat failed on {device}");
    }
    Ok(())
}

#[cfg(not(feature = "dry-run"))]
pub fn luks_open(device: &str, name: &str, passphrase: &str) -> Result<()> {
    use std::process::{Command, Stdio};
    use std::io::Write;

    let mut child = Command::new("cryptsetup")
        .args(["open", "--type", "luks2", device, name])
        .stdin(Stdio::piped())
        .spawn()?;

    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(passphrase.as_bytes())?;
    }
    let status = child.wait()?;
    if !status.success() {
        anyhow::bail!("cryptsetup open failed for {device}");
    }
    Ok(())
}

#[cfg(feature = "dry-run")]
pub fn luks_format(device: &str, _passphrase: &str) -> Result<()> {
    eprintln!("[dry-run] cryptsetup luksFormat {device}");
    Ok(())
}

#[cfg(feature = "dry-run")]
pub fn luks_open(device: &str, name: &str, _passphrase: &str) -> Result<()> {
    eprintln!("[dry-run] cryptsetup open {device} {name}");
    Ok(())
}
