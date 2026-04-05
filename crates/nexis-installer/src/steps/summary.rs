use crossterm::event::{KeyCode, KeyEvent};
use ratatui::{
    layout::{Constraint, Direction, Layout},
    style::Stylize,
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph, Wrap},
    Frame,
};

use crate::app::InstallConfig;
use crate::steps::{Step, StepAction};
use crate::theme;
use crate::ui;

pub struct SummaryStep;

impl SummaryStep {
    pub fn new() -> Self {
        Self
    }
}

impl Step for SummaryStep {
    fn title(&self) -> &str {
        "Summary"
    }

    fn render(&mut self, frame: &mut Frame, config: &InstallConfig) {
        let (header, body, footer) = ui::page_layout(frame.area());
        ui::render_header(frame, header, self.title(), 13, 16);

        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Min(1), Constraint::Length(3)])
            .split(body);

        let mut lines = Vec::new();

        fn row<'a>(label: &'a str, value: &'a str) -> Line<'a> {
            Line::from(vec![
                Span::styled(format!("  {label:<20}"), theme::muted()),
                Span::styled(value, theme::base().bold()),
            ])
        }

        lines.push(Line::from(""));

        lines.push(row(
            "Locale:",
            config.locale.as_deref().unwrap_or("not set"),
        ));
        lines.push(row(
            "Keyboard:",
            config.keymap.as_deref().unwrap_or("not set"),
        ));
        lines.push(row(
            "Hostname:",
            config.hostname.as_deref().unwrap_or("not set"),
        ));
        lines.push(row(
            "Timezone:",
            config.timezone.as_deref().unwrap_or("not set"),
        ));
        lines.push(row(
            "Profile:",
            config.profile.as_deref().unwrap_or("not set"),
        ));

        lines.push(Line::from(""));

        if let Some(disk) = &config.disk {
            lines.push(row("Disk:", &disk.device));
            lines.push(row("Filesystem:", &disk.filesystem));
            let swap = if disk.use_swap {
                format!("{} MiB", disk.swap_size_mb)
            } else {
                "disabled".to_string()
            };
            lines.push(row("Swap:", &swap));

            let encrypted = disk
                .encryption
                .as_ref()
                .map_or("no", |e| if e.enabled { "yes (LUKS2)" } else { "no" });
            lines.push(row("Encryption:", encrypted));
        }

        lines.push(Line::from(""));

        if let Some(user) = &config.user {
            let admin = if user.is_admin { " (wheel)" } else { "" };
            lines.push(row("User:", &format!("{}{admin}", user.username)));
        }
        lines.push(row("Root password:", "********"));

        lines.push(Line::from(""));
        lines.push(Line::from(Span::styled(
            "  Press Enter to begin installation. THIS WILL ERASE THE SELECTED DISK.",
            theme::warning(),
        )));

        let block = Block::default()
            .title(" Review your settings ")
            .title_style(theme::title())
            .borders(Borders::ALL)
            .border_style(theme::border());

        let paragraph = Paragraph::new(lines)
            .block(block)
            .wrap(Wrap { trim: false });
        frame.render_widget(paragraph, chunks[0]);

        ui::render_footer(
            frame,
            footer,
            &[("Enter", "Install"), ("Esc", "Go back and edit")],
        );
    }

    fn handle_key(&mut self, key: KeyEvent, _config: &mut InstallConfig) -> StepAction {
        match key.code {
            KeyCode::Enter => StepAction::Next,
            KeyCode::Esc => StepAction::Prev,
            _ => StepAction::None,
        }
    }
}
