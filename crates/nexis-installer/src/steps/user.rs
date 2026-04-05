use crossterm::event::{KeyCode, KeyEvent};
use ratatui::{
    layout::{Constraint, Direction, Layout},
    Frame,
};

use crate::app::{InstallConfig, UserConfig};
use crate::steps::{Step, StepAction};
use crate::ui;
use crate::ui::widgets::{TextInput, Toggle};

enum Focus {
    Username,
    Password,
    Confirm,
    Admin,
}

pub struct UserStep {
    username: TextInput,
    password: TextInput,
    confirm: TextInput,
    admin: Toggle,
    focus: Focus,
    error: Option<String>,
}

impl UserStep {
    pub fn new() -> Self {
        Self {
            username: TextInput::new("Username"),
            password: TextInput::password("Password"),
            confirm: TextInput::password("Confirm password"),
            admin: Toggle::new("Add to wheel group (sudo access)", true),
            focus: Focus::Username,
            error: None,
        }
    }
}

impl Step for UserStep {
    fn title(&self) -> &str {
        "User Account"
    }

    fn render(&mut self, frame: &mut Frame, _config: &InstallConfig) {
        let (header, body, footer) = ui::page_layout(frame.area());
        ui::render_header(frame, header, self.title(), 11, 16);

        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(3),
                Constraint::Length(3),
                Constraint::Length(3),
                Constraint::Length(2),
                Constraint::Length(2),
                Constraint::Min(0),
            ])
            .split(body);

        self.username
            .render(frame, chunks[0], matches!(self.focus, Focus::Username));
        self.password
            .render(frame, chunks[1], matches!(self.focus, Focus::Password));
        self.confirm
            .render(frame, chunks[2], matches!(self.focus, Focus::Confirm));
        self.admin
            .render(frame, chunks[3], matches!(self.focus, Focus::Admin));

        if let Some(err) = &self.error {
            let msg =
                ratatui::widgets::Paragraph::new(err.as_str()).style(crate::theme::error());
            frame.render_widget(msg, chunks[4]);
        }

        ui::render_footer(
            frame,
            footer,
            &[("Tab", "Next field"), ("Space", "Toggle"), ("Enter", "Continue"), ("Esc", "Back")],
        );
    }

    fn handle_key(&mut self, key: KeyEvent, config: &mut InstallConfig) -> StepAction {
        match key.code {
            KeyCode::Tab => {
                self.focus = match self.focus {
                    Focus::Username => Focus::Password,
                    Focus::Password => Focus::Confirm,
                    Focus::Confirm => Focus::Admin,
                    Focus::Admin => Focus::Username,
                };
                StepAction::None
            }
            KeyCode::BackTab => {
                self.focus = match self.focus {
                    Focus::Username => Focus::Admin,
                    Focus::Password => Focus::Username,
                    Focus::Confirm => Focus::Password,
                    Focus::Admin => Focus::Confirm,
                };
                StepAction::None
            }
            KeyCode::Enter => {
                let name = self.username.value.trim().to_string();
                if name.is_empty() {
                    self.error = Some("Username cannot be empty.".to_string());
                    return StepAction::None;
                }
                if !name
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
                {
                    self.error = Some("Username: lowercase letters, digits, _ and - only.".to_string());
                    return StepAction::None;
                }
                if self.password.value.is_empty() {
                    self.error = Some("Password cannot be empty.".to_string());
                    return StepAction::None;
                }
                if self.password.value != self.confirm.value {
                    self.error = Some("Passwords do not match.".to_string());
                    return StepAction::None;
                }

                config.user = Some(UserConfig {
                    username: name,
                    password: self.password.value.clone(),
                    is_admin: self.admin.enabled,
                });
                self.error = None;
                StepAction::Next
            }
            KeyCode::Esc => StepAction::Prev,
            _ => {
                match self.focus {
                    Focus::Admin => {
                        if key.code == KeyCode::Char(' ') {
                            self.admin.toggle();
                        }
                    }
                    _ => {
                        let input = match self.focus {
                            Focus::Username => &mut self.username,
                            Focus::Password => &mut self.password,
                            Focus::Confirm => &mut self.confirm,
                            Focus::Admin => unreachable!(),
                        };
                        match key.code {
                            KeyCode::Char(c) => input.insert(c),
                            KeyCode::Backspace => input.backspace(),
                            KeyCode::Delete => input.delete(),
                            KeyCode::Left => input.move_left(),
                            KeyCode::Right => input.move_right(),
                            _ => {}
                        }
                    }
                }
                StepAction::None
            }
        }
    }
}
