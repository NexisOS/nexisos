use crossterm::event::{KeyCode, KeyEvent};
use ratatui::Frame;

use crate::app::InstallConfig;
use crate::steps::{Step, StepAction};
use crate::system::fs as fsops;
use crate::ui;
use crate::ui::widgets::SelectList;

pub struct FilesystemStep {
    list: SelectList,
}

impl FilesystemStep {
    pub fn new() -> Self {
        let items = fsops::FILESYSTEMS
            .iter()
            .map(|(name, desc)| format!("{name:6} — {desc}"))
            .collect();
        Self {
            list: SelectList::new(items),
        }
    }
}

impl Step for FilesystemStep {
    fn title(&self) -> &str {
        "Filesystem"
    }

    fn render(&mut self, frame: &mut Frame, _config: &InstallConfig) {
        let (header, body, footer) = ui::page_layout(frame.area());
        ui::render_header(frame, header, self.title(), 6, 16);
        self.list.render(frame, body, "Select root filesystem");
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
                    if let Some((name, _)) = fsops::FILESYSTEMS.get(idx) {
                        let disk = config.disk.get_or_insert_with(Default::default);
                        disk.filesystem = name.to_string();
                    }
                }
                StepAction::Next
            }
            KeyCode::Esc => StepAction::Prev,
            _ => StepAction::None,
        }
    }
}
