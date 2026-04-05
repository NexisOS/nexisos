use anyhow::{Context, Result};

use crate::app::{DiskConfig, InstallConfig};
use crate::system::{bootloader, crypt, fs};
use crate::util::cmd;

const MOUNT_ROOT: &str = "/mnt/nexis";
const ROOTFS_IMAGE: &str = "/run/nexis-installer/rootfs.tar.zst";

/// Progress callback: (step_index, total_steps, description).
pub type ProgressFn<'a> = &'a mut dyn FnMut(usize, usize, &str);

/// Run the full installation.
pub fn run_install(config: &InstallConfig, progress: ProgressFn) -> Result<()> {
    let disk = config
        .disk
        .as_ref()
        .expect("disk config must be set before install");
    let steps = count_steps(config);
    let mut step = 0;

    // 1. Partition the disk.
    progress(step, steps, "Partitioning disk...");
    let parts = crate::system::disk::partition_auto(
        &disk.device,
        if disk.use_swap { disk.swap_size_mb } else { 0 },
        disk.use_swap,
    )?;
    step += 1;

    // 2. Determine root device (may go through LUKS).
    let (efi_part, swap_part, root_raw) = if disk.use_swap {
        (&parts[0], Some(&parts[1]), &parts[2])
    } else {
        (&parts[0], None, &parts[1])
    };

    let root_dev = if let Some(enc) = &disk.encryption {
        if enc.enabled {
            progress(step, steps, "Setting up encryption...");
            crypt::luks_format(root_raw, &enc.passphrase)?;
            let mapped = crypt::luks_open(root_raw, &enc.passphrase)?;
            step += 1;
            mapped
        } else {
            root_raw.clone()
        }
    } else {
        root_raw.clone()
    };

    // 3. Create filesystems.
    progress(step, steps, "Creating filesystems...");
    fs::mkfs_efi(efi_part)?;
    fs::mkfs(&root_dev, &disk.filesystem, "nexis-root")?;
    if let Some(swap) = swap_part {
        fs::mkswap(swap)?;
    }
    step += 1;

    // 4. Mount target.
    progress(step, steps, "Mounting filesystems...");
    fs::mount(&root_dev, MOUNT_ROOT)?;
    let boot_efi = format!("{MOUNT_ROOT}/boot/efi");
    std::fs::create_dir_all(&boot_efi)?;
    fs::mount(efi_part, &boot_efi)?;
    step += 1;

    // 5. Extract rootfs.
    progress(step, steps, "Extracting system image...");
    cmd::run(
        "tar",
        &["--zstd", "-xpf", ROOTFS_IMAGE, "-C", MOUNT_ROOT],
    )
    .context("failed to extract rootfs image")?;
    step += 1;

    // 6. Write system configuration.
    progress(step, steps, "Configuring system...");
    write_system_config(config)?;
    step += 1;

    // 7. Install bootloader.
    progress(step, steps, "Installing bootloader...");
    if bootloader::is_efi() {
        bootloader::install_grub_efi()?;
    } else {
        bootloader::install_grub_bios(&disk.device)?;
    }
    step += 1;

    // 8. Set up users.
    progress(step, steps, "Creating user accounts...");
    setup_users(config)?;
    step += 1;

    // 9. Finalize.
    progress(step, steps, "Finishing up...");
    finalize()?;

    Ok(())
}

fn count_steps(config: &InstallConfig) -> usize {
    let mut n = 8; // base steps
    if config
        .disk
        .as_ref()
        .and_then(|d| d.encryption.as_ref())
        .map_or(false, |e| e.enabled)
    {
        n += 1;
    }
    n
}

fn write_system_config(config: &InstallConfig) -> Result<()> {
    let etc = format!("{MOUNT_ROOT}/etc/nexis");
    std::fs::create_dir_all(&etc)?;

    // Write the system.toml with all user choices.
    let mut toml_content = String::new();
    toml_content.push_str("[system]\n");

    if let Some(hostname) = &config.hostname {
        toml_content.push_str(&format!("hostname = \"{hostname}\"\n"));
    }
    if let Some(locale) = &config.locale {
        toml_content.push_str(&format!("locale = \"{locale}\"\n"));
    }
    if let Some(keymap) = &config.keymap {
        toml_content.push_str(&format!("keymap = \"{keymap}\"\n"));
    }
    if let Some(tz) = &config.timezone {
        toml_content.push_str(&format!("timezone = \"{tz}\"\n"));
    }
    if let Some(profile) = &config.profile {
        toml_content.push_str(&format!("\n[profile]\nname = \"{profile}\"\n"));
    }

    std::fs::write(format!("{etc}/system.toml"), toml_content)?;

    // Hostname.
    if let Some(hostname) = &config.hostname {
        std::fs::write(format!("{MOUNT_ROOT}/etc/hostname"), hostname)?;
    }

    // Timezone.
    if let Some(tz) = &config.timezone {
        let tz_path = format!("/usr/share/zoneinfo/{tz}");
        let link_path = format!("{MOUNT_ROOT}/etc/localtime");
        let _ = std::fs::remove_file(&link_path);
        std::os::unix::fs::symlink(&tz_path, &link_path)?;
    }

    // Locale.
    if let Some(locale) = &config.locale {
        std::fs::write(
            format!("{MOUNT_ROOT}/etc/locale.conf"),
            format!("LANG={locale}\n"),
        )?;
    }

    // Keymap.
    if let Some(keymap) = &config.keymap {
        std::fs::write(
            format!("{MOUNT_ROOT}/etc/vconsole.conf"),
            format!("KEYMAP={keymap}\n"),
        )?;
    }

    // fstab generation.
    generate_fstab(config)?;

    Ok(())
}

fn generate_fstab(config: &InstallConfig) -> Result<()> {
    cmd::run_stdout("genfstab", &["-U", MOUNT_ROOT])
        .and_then(|fstab| {
            std::fs::write(format!("{MOUNT_ROOT}/etc/fstab"), fstab)
                .context("failed to write fstab")
        })
        .or_else(|_| {
            // Fallback: generate a minimal fstab if genfstab is not available.
            let fstab = "# /etc/fstab - generated by nexis-installer\n\
                         # <device>  <mount>  <type>  <options>  <dump>  <fsck>\n";
            std::fs::write(format!("{MOUNT_ROOT}/etc/fstab"), fstab)
                .context("failed to write fstab")
        })
}

fn setup_users(config: &InstallConfig) -> Result<()> {
    // Set root password.
    if let Some(pass) = &config.root_password {
        cmd::run_with_stdin(
            "chroot",
            &[MOUNT_ROOT, "chpasswd"],
            &format!("root:{pass}\n"),
        )?;
    }

    // Create user account.
    if let Some(user) = &config.user {
        let mut args = vec![
            MOUNT_ROOT,
            "useradd",
            "-m",
            "-s",
            "/bin/bash",
        ];
        if user.is_admin {
            args.extend_from_slice(&["-G", "wheel"]);
        }
        args.push(&user.username);
        cmd::run("chroot", &args)?;

        cmd::run_with_stdin(
            "chroot",
            &[MOUNT_ROOT, "chpasswd"],
            &format!("{}:{}\n", user.username, user.password),
        )?;
    }

    Ok(())
}

fn finalize() -> Result<()> {
    // Sync and unmount.
    cmd::run("sync", &[])?;
    fs::umount(MOUNT_ROOT)?;
    Ok(())
}
