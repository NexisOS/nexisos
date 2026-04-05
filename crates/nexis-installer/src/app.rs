use anyhow::Result;
use crossterm::event::KeyEvent;
use ratatui::Frame;
use serde::{Deserialize, Serialize};

use crate::steps::{self, Step, StepAction};

/// All user choices accumulated across steps.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct InstallConfig {
    pub locale: Option<String>,
    pub keymap: Option<String>,
    pub hostname: Option<String>,
    pub timezone: Option<String>,
    pub root_password: Option<String>,
    pub user: Option<UserConfig>,
    pub disk: Option<DiskConfig>,
    pub network: Option<NetworkConfig>,
    pub profile: Option<String>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct UserConfig {
    pub username: String,
    pub password: String,
    pub is_admin: bool,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct DiskConfig {
    pub device: String,
    pub partitions: Vec<PartitionEntry>,
    pub encryption: Option<EncryptionConfig>,
    pub filesystem: String,
    pub use_swap: bool,
    pub swap_size_mb: u64,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct PartitionEntry {
    pub mount_point: String,
    pub size_mb: u64,
    pub fs_type: String,
    pub label: String,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct EncryptionConfig {
    pub enabled: bool,
    pub passphrase: String,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct NetworkConfig {
    pub interface: String,
    pub use_dhcp: bool,
    pub static_ip: Option<String>,
    pub gateway: Option<String>,
    pub dns: Vec<String>,
    pub wifi_ssid: Option<String>,
}

pub struct App {
    pub config: InstallConfig,
    steps: Vec<Box<dyn Step>>,
    current: usize,
    exit: bool,
    reboot: bool,
}

impl App {
    pub fn new() -> Result<Self> {
        let steps: Vec<Box<dyn Step>> = vec![
            Box::new(steps::welcome::WelcomeStep::new()),
            Box::new(steps::locale::LocaleStep::new()),
            Box::new(steps::keyboard::KeyboardStep::new()),
            Box::new(steps::network::NetworkStep::new()),
            Box::new(steps::disk::DiskStep::new()),
            Box::new(steps::partition::PartitionStep::new()),
            Box::new(steps::filesystem::FilesystemStep::new()),
            Box::new(steps::encryption::EncryptionStep::new()),
            Box::new(steps::hostname::HostnameStep::new()),
            Box::new(steps::timezone::TimezoneStep::new()),
            Box::new(steps::rootpass::RootPassStep::new()),
            Box::new(steps::user::UserStep::new()),
            Box::new(steps::profile::ProfileStep::new()),
            Box::new(steps::summary::SummaryStep::new()),
            Box::new(steps::install::InstallStep::new()),
            Box::new(steps::complete::CompleteStep::new()),
        ];

        Ok(Self {
            config: InstallConfig::default(),
            steps,
            current: 0,
            exit: false,
            reboot: false,
        })
    }

    pub fn render(&mut self, frame: &mut Frame) {
        if let Some(step) = self.steps.get_mut(self.current) {
            step.render(frame, &self.config);
        }
    }

    pub fn handle_key(&mut self, key: KeyEvent) {
        let action = if let Some(step) = self.steps.get_mut(self.current) {
            step.handle_key(key, &mut self.config)
        } else {
            StepAction::None
        };

        match action {
            StepAction::Next => self.next_step(),
            StepAction::Prev => self.prev_step(),
            StepAction::Quit => self.exit = true,
            StepAction::Reboot => {
                self.exit = true;
                self.reboot = true;
            }
            StepAction::None => {}
        }
    }

    fn next_step(&mut self) {
        if self.current + 1 < self.steps.len() {
            self.current += 1;
            self.steps[self.current].on_enter(&self.config);
        }
    }

    fn prev_step(&mut self) {
        if self.current > 0 {
            self.current -= 1;
        }
    }

    pub fn can_quit(&self) -> bool {
        // Allow quitting only before the install step begins.
        self.current < self.steps.len() - 2
    }

    pub fn should_exit(&self) -> bool {
        self.exit
    }

    pub fn should_reboot(&self) -> bool {
        self.reboot
    }
}
