use crossterm::event::{KeyCode, KeyEvent};
use ratatui::{
    layout::{Constraint, Direction, Layout},
    Frame,
};

use crate::app::InstallConfig;
use crate::steps::{Step, StepAction};
use crate::ui;
use crate::ui::widgets::TextInput;

enum Focus {
    Password,
    Confirm,
}

pub struct RootPassStep {
    password: TextInput,
    confirm: TextInput,
    focus: Focus,
    error: Option<String>,
}

impl RootPassStep {
    pub fn new() -> Self {
        Self {
            password: TextInput::password("Root password"),
            confirm: TextInput::password("Confirm password"),
            focus: Focus::Password,
            error: None,
        }
    }
}

impl Step for RootPassStep {
    fn title(&self) -> &str {
        "Root Password"
    }

    fn render(&mut self, frame: &mut Frame, _config: &InstallConfig) {
        let (header, body, footer) = ui::page_layout(frame.area());
        ui::render_header(frame, header, self.title(), 10, 16);

        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(3),
                Constraint::Length(3),
                Constraint::Length(2),
                Constraint::Min(0),
            ])
            .split(body);

        self.password
            .render(frame, chunks[0], matches!(self.focus, Focus::Password));
        self.confirm
            .render(frame, chunks[1], matches!(self.focus, Focus::Confirm));

        if let Some(err) = &self.error {
            let msg =
                ratatui::widgets::Paragraph::new(err.as_str()).style(crate::theme::error());
            frame.render_widget(msg, chunks[2]);
        }

        ui::render_footer(
            frame,
            footer,
            &[("Tab", "Next field"), ("Enter", "Continue"), ("Esc", "Back")],
        );
    }

    fn handle_key(&mut self, key: KeyEvent, config: &mut InstallConfig) -> StepAction {
        match key.code {
            KeyCode::Tab | KeyCode::BackTab => {
                self.focus = match self.focus {
                    Focus::Password => Focus::Confirm,
                    Focus::Confirm => Focus::Password,
                };
                StepAction::None
            }
            KeyCode::Enter => {
                if self.password.value.is_empty() {
                    self.error = Some("Password cannot be empty.".to_string());
                    return StepAction::None;
                }
                if self.password.value != self.confirm.value {
                    self.error = Some("Passwords do not match.".to_string());
                    return StepAction::None;
                }
                config.root_password = Some(self.password.value.clone());
                self.error = None;
                StepAction::Next
            }
            KeyCode::Esc => StepAction::Prev,
            _ => {
                let input = match self.focus {
                    Focus::Password => &mut self.password,
                    Focus::Confirm => &mut self.confirm,
                };
                match key.code {
                    KeyCode::Char(c) => input.insert(c),
                    KeyCode::Backspace => input.backspace(),
                    KeyCode::Delete => input.delete(),
                    KeyCode::Left => input.move_left(),
                    KeyCode::Right => input.move_right(),
                    _ => {}
                }
                StepAction::None
            }
        }
    }
}
