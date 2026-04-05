pub mod complete;
pub mod disk;
pub mod encryption;
pub mod filesystem;
pub mod hostname;
pub mod install;
pub mod keyboard;
pub mod locale;
pub mod network;
pub mod partition;
pub mod profile;
pub mod rootpass;
pub mod summary;
pub mod timezone;
pub mod user;
pub mod welcome;

use crossterm::event::KeyEvent;
use ratatui::Frame;

use crate::app::InstallConfig;

/// What a step tells the app to do after handling a key.
pub enum StepAction {
    None,
    Next,
    Prev,
    Quit,
    Reboot,
}

/// Every installer screen implements this trait.
pub trait Step {
    /// Unique title shown in the header/progress bar.
    fn title(&self) -> &str;

    /// Draw the step's UI.
    fn render(&mut self, frame: &mut Frame, config: &InstallConfig);

    /// Handle a key press. May mutate the shared config.
    fn handle_key(&mut self, key: KeyEvent, config: &mut InstallConfig) -> StepAction;

    /// Called when navigating into this step (refresh data, etc.).
    fn on_enter(&mut self, _config: &InstallConfig) {}
}
