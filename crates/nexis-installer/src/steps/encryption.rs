use crossterm::event::{KeyCode, KeyEvent};
use ratatui::{
    layout::{Constraint, Direction, Layout},
    Frame,
};

use crate::app::{EncryptionConfig, InstallConfig};
use crate::steps::{Step, StepAction};
use crate::ui;
use crate::ui::widgets::{TextInput, Toggle};

enum Focus {
    EnableToggle,
    Passphrase,
    Confirm,
}

pub struct EncryptionStep {
    toggle: Toggle,
    passphrase: TextInput,
    confirm: TextInput,
    focus: Focus,
    error: Option<String>,
}

impl EncryptionStep {
    pub fn new() -> Self {
        Self {
            toggle: Toggle::new("Enable LUKS disk encryption", false),
            passphrase: TextInput::password("Encryption passphrase"),
            confirm: TextInput::password("Confirm passphrase"),
            focus: Focus::EnableToggle,
            error: None,
        }
    }
}

impl Step for EncryptionStep {
    fn title(&self) -> &str {
        "Encryption"
    }

    fn render(&mut self, frame: &mut Frame, _config: &InstallConfig) {
        let (header, body, footer) = ui::page_layout(frame.area());
        ui::render_header(frame, header, self.title(), 7, 16);

        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(2),
                Constraint::Length(3),
                Constraint::Length(3),
                Constraint::Length(2),
                Constraint::Min(0),
            ])
            .split(body);

        self.toggle
            .render(frame, chunks[0], matches!(self.focus, Focus::EnableToggle));

        if self.toggle.enabled {
            self.passphrase
                .render(frame, chunks[1], matches!(self.focus, Focus::Passphrase));
            self.confirm
                .render(frame, chunks[2], matches!(self.focus, Focus::Confirm));

            if let Some(err) = &self.error {
                let msg = ratatui::widgets::Paragraph::new(err.as_str())
                    .style(crate::theme::error());
                frame.render_widget(msg, chunks[3]);
            }
        }

        ui::render_footer(
            frame,
            footer,
            &[
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
                    Focus::EnableToggle if self.toggle.enabled => Focus::Passphrase,
                    Focus::EnableToggle => Focus::EnableToggle,
                    Focus::Passphrase => Focus::Confirm,
                    Focus::Confirm => Focus::EnableToggle,
                };
                StepAction::None
            }
            KeyCode::Enter => {
                if self.toggle.enabled {
                    if self.passphrase.value.is_empty() {
                        self.error = Some("Passphrase cannot be empty.".to_string());
                        return StepAction::None;
                    }
                    if self.passphrase.value != self.confirm.value {
                        self.error = Some("Passphrases do not match.".to_string());
                        return StepAction::None;
                    }
                    if self.passphrase.value.len() < 8 {
                        self.error = Some("Passphrase must be at least 8 characters.".to_string());
                        return StepAction::None;
                    }
                }

                let disk = config.disk.get_or_insert_with(Default::default);
                disk.encryption = Some(EncryptionConfig {
                    enabled: self.toggle.enabled,
                    passphrase: self.passphrase.value.clone(),
                });
                self.error = None;
                StepAction::Next
            }
            KeyCode::Esc => StepAction::Prev,
            _ => {
                match self.focus {
                    Focus::EnableToggle => {
                        if key.code == KeyCode::Char(' ') {
                            self.toggle.toggle();
                        }
                    }
                    Focus::Passphrase => match key.code {
                        KeyCode::Char(c) => self.passphrase.insert(c),
                        KeyCode::Backspace => self.passphrase.backspace(),
                        KeyCode::Left => self.passphrase.move_left(),
                        KeyCode::Right => self.passphrase.move_right(),
                        _ => {}
                    },
                    Focus::Confirm => match key.code {
                        KeyCode::Char(c) => self.confirm.insert(c),
                        KeyCode::Backspace => self.confirm.backspace(),
                        KeyCode::Left => self.confirm.move_left(),
                        KeyCode::Right => self.confirm.move_right(),
                        _ => {}
                    },
                }
                StepAction::None
            }
        }
    }
}
