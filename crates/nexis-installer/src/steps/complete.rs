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

pub struct CompleteStep;

impl CompleteStep {
    pub fn new() -> Self {
        Self
    }
}

impl Step for CompleteStep {
    fn title(&self) -> &str {
        "Complete"
    }

    fn render(&mut self, frame: &mut Frame, _config: &InstallConfig) {
        let (header, body, footer) = ui::page_layout(frame.area());
        ui::render_header(frame, header, self.title(), 15, 16);

        let center = ui::centered(body, 60, 10);
        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(3),
                Constraint::Length(2),
                Constraint::Length(3),
                Constraint::Min(0),
            ])
            .split(center);

        let title = Paragraph::new(Line::from(vec![
            Span::styled("✓ ", theme::success()),
            Span::styled("NexisOS has been installed successfully!", theme::title()),
        ]));
        frame.render_widget(title, chunks[0]);

        let info = Paragraph::new(Line::from(Span::styled(
            "Remove the installation media and press Enter to reboot.",
            theme::base(),
        )));
        frame.render_widget(info, chunks[1]);

        let hint = Paragraph::new(Line::from(Span::styled(
            "Or press 's' to drop to a shell for post-install tweaks.",
            theme::muted(),
        )));
        frame.render_widget(hint, chunks[2]);

        ui::render_footer(frame, footer, &[("Enter", "Reboot"), ("s", "Shell")]);
    }

    fn handle_key(&mut self, key: KeyEvent, _config: &mut InstallConfig) -> StepAction {
        match key.code {
            KeyCode::Enter => StepAction::Reboot,
            KeyCode::Char('s') => {
                // Drop to shell — restore terminal and exec sh.
                let _ = crossterm::terminal::disable_raw_mode();
                let _ = crossterm::execute!(
                    std::io::stdout(),
                    crossterm::terminal::LeaveAlternateScreen
                );
                let status = std::process::Command::new("/bin/sh")
                    .status();
                // Re-enter TUI after shell exits.
                let _ = crossterm::terminal::enable_raw_mode();
                let _ = crossterm::execute!(
                    std::io::stdout(),
                    crossterm::terminal::EnterAlternateScreen
                );
                let _ = status;
                StepAction::None
            }
            _ => StepAction::None,
        }
    }
}
