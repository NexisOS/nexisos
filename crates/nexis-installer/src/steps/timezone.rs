use crossterm::event::{KeyCode, KeyEvent};
use ratatui::Frame;

use crate::app::InstallConfig;
use crate::steps::{Step, StepAction};
use crate::ui;
use crate::ui::widgets::SelectList;

const TIMEZONES: &[&str] = &[
    "America/New_York",
    "America/Chicago",
    "America/Denver",
    "America/Los_Angeles",
    "America/Anchorage",
    "Pacific/Honolulu",
    "America/Toronto",
    "America/Sao_Paulo",
    "Europe/London",
    "Europe/Paris",
    "Europe/Berlin",
    "Europe/Moscow",
    "Asia/Tokyo",
    "Asia/Shanghai",
    "Asia/Kolkata",
    "Asia/Dubai",
    "Australia/Sydney",
    "Pacific/Auckland",
    "Africa/Cairo",
    "Africa/Johannesburg",
    "UTC",
];

pub struct TimezoneStep {
    list: SelectList,
}

impl TimezoneStep {
    pub fn new() -> Self {
        Self {
            list: SelectList::new(TIMEZONES.iter().map(|s| s.to_string()).collect()),
        }
    }
}

impl Step for TimezoneStep {
    fn title(&self) -> &str {
        "Timezone"
    }

    fn render(&mut self, frame: &mut Frame, _config: &InstallConfig) {
        let (header, body, footer) = ui::page_layout(frame.area());
        ui::render_header(frame, header, self.title(), 9, 16);
        self.list.render(frame, body, "Select your timezone");
        ui::render_footer(
            frame,
            footer,
            &[("↑/↓", "Navigate"), ("Enter", "Select"), ("Esc", "Back")],
        );
    }

    fn handle_key(&mut self, key: KeyEvent, config: &mut InstallConfig) -> StepAction {
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => { self.list.prev(); StepAction::None }
            KeyCode::Down | KeyCode::Char('j') => { self.list.next(); StepAction::None }
            KeyCode::Enter => {
                config.timezone = self.list.selected_value().map(|s| s.to_string());
                StepAction::Next
            }
            KeyCode::Esc => StepAction::Prev,
            _ => StepAction::None,
        }
    }
}
