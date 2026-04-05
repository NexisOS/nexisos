use crossterm::event::{KeyCode, KeyEvent};
use ratatui::Frame;

use crate::app::InstallConfig;
use crate::steps::{Step, StepAction};
use crate::ui;
use crate::ui::widgets::SelectList;

const KEYMAPS: &[&str] = &[
    "us", "uk", "de", "fr", "es", "it", "pt", "br", "jp", "kr", "ru", "se", "no", "dk", "fi",
    "ch", "be", "nl", "pl", "cz", "dvorak", "colemak",
];

pub struct KeyboardStep {
    list: SelectList,
}

impl KeyboardStep {
    pub fn new() -> Self {
        Self {
            list: SelectList::new(KEYMAPS.iter().map(|s| s.to_string()).collect()),
        }
    }
}

impl Step for KeyboardStep {
    fn title(&self) -> &str {
        "Keyboard"
    }

    fn render(&mut self, frame: &mut Frame, _config: &InstallConfig) {
        let (header, body, footer) = ui::page_layout(frame.area());
        ui::render_header(frame, header, self.title(), 2, 16);
        self.list.render(frame, body, "Select keyboard layout");
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
                config.keymap = self.list.selected_value().map(|s| s.to_string());
                StepAction::Next
            }
            KeyCode::Esc => StepAction::Prev,
            _ => StepAction::None,
        }
    }
}
