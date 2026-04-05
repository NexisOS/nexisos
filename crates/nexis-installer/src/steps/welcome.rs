use crossterm::event::{KeyCode, KeyEvent};
use ratatui::{
    layout::{Constraint, Direction, Layout},
    style::Stylize,
    text::{Line, Span},
    widgets::Paragraph,
    Frame,
};

use crate::app::InstallConfig;
use crate::steps::{Step, StepAction};
use crate::theme;
use crate::ui;

const LOGO: &str = r#"
    _   __          _      ____  _____
   / | / /__  _  __(_)____/ __ \/ ___/
  /  |/ / _ \| |/_/ / ___/ / / /\__ \ 
 / /|  /  __/>  </ (__  ) /_/ /___/ / 
/_/ |_/\___/_/|_/_/____/\____//____/  
"#;

pub struct WelcomeStep;

impl WelcomeStep {
    pub fn new() -> Self {
        Self
    }
}

impl Step for WelcomeStep {
    fn title(&self) -> &str {
        "Welcome"
    }

    fn render(&mut self, frame: &mut Frame, _config: &InstallConfig) {
        let (header, body, footer) = ui::page_layout(frame.area());
        ui::render_header(frame, header, self.title(), 0, 16);

        let center = ui::centered(body, 60, 14);
        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(6),
                Constraint::Length(2),
                Constraint::Length(3),
                Constraint::Min(0),
            ])
            .split(center);

        let logo = Paragraph::new(LOGO).style(theme::title());
        frame.render_widget(logo, chunks[0]);

        let tagline = Paragraph::new(Line::from(vec![
            Span::styled("Welcome to the ", theme::base()),
            Span::styled("NexisOS", theme::title()),
            Span::styled(" installer.", theme::base()),
        ]));
        frame.render_widget(tagline, chunks[1]);

        let hint = Paragraph::new(Line::from(vec![Span::styled(
            "This will guide you through installing NexisOS on your machine.",
            theme::muted(),
        )]));
        frame.render_widget(hint, chunks[2]);

        ui::render_footer(frame, footer, &[("Enter", "Start"), ("q", "Quit")]);
    }

    fn handle_key(&mut self, key: KeyEvent, _config: &mut InstallConfig) -> StepAction {
        match key.code {
            KeyCode::Enter => StepAction::Next,
            _ => StepAction::None,
        }
    }
}
