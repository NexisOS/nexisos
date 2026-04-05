use crossterm::event::{KeyCode, KeyEvent};
use ratatui::{
    layout::{Constraint, Direction, Layout},
    Frame,
};

use crate::app::InstallConfig;
use crate::steps::{Step, StepAction};
use crate::ui;
use crate::ui::widgets::{SelectList, TextInput, Toggle};

enum Focus {
    SchemeSelect,
    SwapToggle,
    SwapSize,
}

pub struct PartitionStep {
    scheme: SelectList,
    swap_toggle: Toggle,
    swap_size: TextInput,
    focus: Focus,
}

impl PartitionStep {
    pub fn new() -> Self {
        Self {
            scheme: SelectList::new(vec![
                "Automatic — EFI + Root (recommended)".to_string(),
                "Automatic — EFI + Swap + Root".to_string(),
            ]),
            swap_toggle: Toggle::new("Enable swap partition", false),
            swap_size: TextInput::new("Swap size (MiB)"),
            focus: Focus::SchemeSelect,
        }
    }
}

impl Step for PartitionStep {
    fn title(&self) -> &str {
        "Partitioning"
    }

    fn render(&mut self, frame: &mut Frame, _config: &InstallConfig) {
        let (header, body, footer) = ui::page_layout(frame.area());
        ui::render_header(frame, header, self.title(), 5, 16);

        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(6),
                Constraint::Length(3),
                Constraint::Length(3),
                Constraint::Min(0),
            ])
            .split(body);

        self.scheme.render(frame, chunks[0], "Partition scheme");
        self.swap_toggle
            .render(frame, chunks[1], matches!(self.focus, Focus::SwapToggle));
        if self.swap_toggle.enabled {
            self.swap_size
                .render(frame, chunks[2], matches!(self.focus, Focus::SwapSize));
        }

        ui::render_footer(
            frame,
            footer,
            &[
                ("↑/↓", "Navigate"),
                ("Tab", "Next field"),
                ("Space", "Toggle"),
                ("Enter", "Continue"),
                ("Esc", "Back"),
            ],
        );
    }

    fn handle_key(&mut self, key: KeyEvent, config: &mut InstallConfig) -> StepAction {
        match key.code {
            KeyCode::Tab => {
                self.focus = match self.focus {
                    Focus::SchemeSelect => Focus::SwapToggle,
                    Focus::SwapToggle if self.swap_toggle.enabled => Focus::SwapSize,
                    Focus::SwapToggle | Focus::SwapSize => Focus::SchemeSelect,
                };
                StepAction::None
            }
            KeyCode::BackTab => {
                self.focus = match self.focus {
                    Focus::SchemeSelect => {
                        if self.swap_toggle.enabled {
                            Focus::SwapSize
                        } else {
                            Focus::SwapToggle
                        }
                    }
                    Focus::SwapToggle => Focus::SchemeSelect,
                    Focus::SwapSize => Focus::SwapToggle,
                };
                StepAction::None
            }
            KeyCode::Enter => {
                let disk = config.disk.get_or_insert_with(Default::default);

                // Check if scheme 1 (with swap) is selected.
                let scheme_has_swap = self.scheme.selected_index() == Some(1);
                disk.use_swap = scheme_has_swap || self.swap_toggle.enabled;

                if disk.use_swap {
                    disk.swap_size_mb = self
                        .swap_size
                        .value
                        .parse::<u64>()
                        .unwrap_or(4096);
                }

                StepAction::Next
            }
            KeyCode::Esc => StepAction::Prev,
            _ => {
                match self.focus {
                    Focus::SchemeSelect => match key.code {
                        KeyCode::Up | KeyCode::Char('k') => self.scheme.prev(),
                        KeyCode::Down | KeyCode::Char('j') => self.scheme.next(),
                        _ => {}
                    },
                    Focus::SwapToggle => {
                        if key.code == KeyCode::Char(' ') {
                            self.swap_toggle.toggle();
                            if !self.swap_toggle.enabled {
                                self.swap_size.value.clear();
                            } else if self.swap_size.value.is_empty() {
                                self.swap_size.value = "4096".to_string();
                                self.swap_size.cursor = 4;
                            }
                        }
                    }
                    Focus::SwapSize => match key.code {
                        KeyCode::Char(c) if c.is_ascii_digit() => self.swap_size.insert(c),
                        KeyCode::Backspace => self.swap_size.backspace(),
                        KeyCode::Left => self.swap_size.move_left(),
                        KeyCode::Right => self.swap_size.move_right(),
                        _ => {}
                    },
                }
                StepAction::None
            }
        }
    }
}
