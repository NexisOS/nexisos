use crossterm::event::{KeyCode, KeyEvent};
use ratatui::Frame;

use crate::app::InstallConfig;
use crate::steps::{Step, StepAction};
use crate::system::disk as diskops;
use crate::ui;
use crate::ui::widgets::SelectList;

pub struct DiskStep {
    list: SelectList,
    devices: Vec<diskops::BlockDevice>,
    error: Option<String>,
}

impl DiskStep {
    pub fn new() -> Self {
        Self {
            list: SelectList::new(vec!["Scanning...".to_string()]),
            devices: Vec::new(),
            error: None,
        }
    }

    fn refresh(&mut self) {
        match diskops::list_disks() {
            Ok(devs) if !devs.is_empty() => {
                let names: Vec<String> = devs
                    .iter()
                    .map(|d| {
                        let model = if d.model.is_empty() {
                            "Unknown".to_string()
                        } else {
                            d.model.clone()
                        };
                        format!("{} — {} ({})", d.path, model, d.size_display())
                    })
                    .collect();
                self.list = SelectList::new(names);
                self.devices = devs;
                self.error = None;
            }
            Ok(_) => {
                self.list = SelectList::new(vec!["No suitable disks found".to_string()]);
                self.error = Some("No writable disks detected.".to_string());
            }
            Err(e) => {
                self.list = SelectList::new(vec!["Error detecting disks".to_string()]);
                self.error = Some(format!("{e}"));
            }
        }
    }
}

impl Step for DiskStep {
    fn title(&self) -> &str {
        "Disk Selection"
    }

    fn on_enter(&mut self, _config: &InstallConfig) {
        self.refresh();
    }

    fn render(&mut self, frame: &mut Frame, _config: &InstallConfig) {
        let (header, body, footer) = ui::page_layout(frame.area());
        ui::render_header(frame, header, self.title(), 4, 16);

        if let Some(err) = &self.error {
            ui::widgets::render_info(frame, body, "Disk Selection", &[err, "", "Press Esc to go back."]);
        } else {
            self.list.render(frame, body, "Select installation disk (ALL DATA WILL BE ERASED)");
        }

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
                    if let Some(dev) = self.devices.get(idx) {
                        let disk = config.disk.get_or_insert_with(Default::default);
                        disk.device = dev.path.clone();
                        return StepAction::Next;
                    }
                }
                StepAction::None
            }
            KeyCode::Esc => StepAction::Prev,
            _ => StepAction::None,
        }
    }
}
