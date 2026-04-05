use crossterm::event::{KeyCode, KeyEvent};
use ratatui::Frame;

use crate::app::InstallConfig;
use crate::steps::{Step, StepAction};
use crate::ui;
use crate::ui::widgets::SelectList;

const PROFILES: &[(&str, &str)] = &[
    ("minimal", "Minimal — base system, no GUI, smallest footprint"),
    ("desktop", "Desktop — Wayland compositor, apps, full experience"),
    ("server", "Server — headless, networking tools, hardened defaults"),
];

pub struct ProfileStep {
    list: SelectList,
}

impl ProfileStep {
    pub fn new() -> Self {
        let items = PROFILES.iter().map(|(_, desc)| desc.to_string()).collect();
        Self {
            list: SelectList::new(items),
        }
    }
}

impl Step for ProfileStep {
    fn title(&self) -> &str {
        "System Profile"
    }

    fn render(&mut self, frame: &mut Frame, _config: &InstallConfig) {
        let (header, body, footer) = ui::page_layout(frame.area());
        ui::render_header(frame, header, self.title(), 12, 16);
        self.list.render(frame, body, "Select system profile");
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
                if let Some(idx) = self.list.selected_index() {
                    if let Some((name, _)) = PROFILES.get(idx) {
                        config.profile = Some(name.to_string());
                    }
                }
                StepAction::Next
            }
            KeyCode::Esc => StepAction::Prev,
            _ => StepAction::None,
        }
    }
}
