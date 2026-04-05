use crossterm::event::{KeyCode, KeyEvent};
use ratatui::{
    layout::{Constraint, Direction, Layout},
    Frame,
};

use crate::app::InstallConfig;
use crate::steps::{Step, StepAction};
use crate::ui;
use crate::ui::widgets::TextInput;

pub struct HostnameStep {
    input: TextInput,
    error: Option<String>,
}

impl HostnameStep {
    pub fn new() -> Self {
        Self {
            input: TextInput::new("Hostname"),
            error: None,
        }
    }
}

impl Step for HostnameStep {
    fn title(&self) -> &str {
        "Hostname"
    }

    fn render(&mut self, frame: &mut Frame, _config: &InstallConfig) {
        let (header, body, footer) = ui::page_layout(frame.area());
        ui::render_header(frame, header, self.title(), 8, 16);

        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(2),
                Constraint::Length(3),
                Constraint::Length(2),
                Constraint::Min(0),
            ])
            .split(body);

        ui::widgets::render_info(frame, chunks[0], "", &["Enter a hostname for this machine."]);
        self.input.render(frame, chunks[1], true);

        if let Some(err) = &self.error {
            let msg = ratatui::widgets::Paragraph::new(err.as_str())
                .style(crate::theme::error());
            frame.render_widget(msg, chunks[2]);
        }

        ui::render_footer(frame, footer, &[("Enter", "Continue"), ("Esc", "Back")]);
    }

    fn handle_key(&mut self, key: KeyEvent, config: &mut InstallConfig) -> StepAction {
        match key.code {
            KeyCode::Enter => {
                let val = self.input.value.trim().to_string();
                if val.is_empty() {
                    self.error = Some("Hostname cannot be empty.".to_string());
                    return StepAction::None;
                }
                if !val
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '-')
                {
                    self.error =
                        Some("Only alphanumeric characters and hyphens allowed.".to_string());
                    return StepAction::None;
                }
                config.hostname = Some(val);
                self.error = None;
                StepAction::Next
            }
            KeyCode::Esc => StepAction::Prev,
            KeyCode::Char(c) => { self.input.insert(c); StepAction::None }
            KeyCode::Backspace => { self.input.backspace(); StepAction::None }
            KeyCode::Left => { self.input.move_left(); StepAction::None }
            KeyCode::Right => { self.input.move_right(); StepAction::None }
            KeyCode::Delete => { self.input.delete(); StepAction::None }
            _ => StepAction::None,
        }
    }
}
