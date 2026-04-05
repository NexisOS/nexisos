use crossterm::event::{KeyCode, KeyEvent};
use ratatui::{
    layout::{Constraint, Direction, Layout},
    text::Line,
    widgets::{Block, Borders, Paragraph, Wrap},
    Frame,
};

use crate::app::InstallConfig;
use crate::steps::{Step, StepAction};
use crate::system::install as sysinstall;
use crate::theme;
use crate::ui;

enum State {
    Ready,
    Running,
    Done,
    Failed(String),
}

pub struct InstallStep {
    state: State,
    progress: f64,
    status: String,
    log: Vec<String>,
}

impl InstallStep {
    pub fn new() -> Self {
        Self {
            state: State::Ready,
            progress: 0.0,
            status: String::new(),
            log: Vec::new(),
        }
    }
}

impl Step for InstallStep {
    fn title(&self) -> &str {
        "Installing"
    }

    fn on_enter(&mut self, config: &InstallConfig) {
        // Begin installation immediately when we enter this step.
        self.state = State::Running;
        self.log.clear();

        // Clone config for the install run. We use a synchronous approach
        // since nexis-init is single-threaded by design — the TUI redraws
        // happen between install stages via the progress callback.
        let config_clone = config.clone();
        let mut step_log: Vec<String> = Vec::new();
        let mut final_progress = 0.0;

        let result = sysinstall::run_install(&config_clone, &mut |step, total, desc| {
            final_progress = step as f64 / total as f64;
            step_log.push(desc.to_string());
        });

        self.log = step_log;
        self.progress = final_progress;

        match result {
            Ok(()) => {
                self.state = State::Done;
                self.progress = 1.0;
                self.status = "Installation complete!".to_string();
            }
            Err(e) => {
                self.state = State::Failed(format!("{e:#}"));
                self.status = format!("Installation failed: {e:#}");
            }
        }
    }

    fn render(&mut self, frame: &mut Frame, _config: &InstallConfig) {
        let (header, body, footer) = ui::page_layout(frame.area());
        ui::render_header(frame, header, self.title(), 14, 16);

        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(3),
                Constraint::Min(1),
            ])
            .split(body);

        // Progress bar.
        ui::widgets::render_progress(frame, chunks[0], "Progress", self.progress);

        // Log output.
        let log_lines: Vec<Line> = self
            .log
            .iter()
            .map(|l| {
                Line::from(format!("  ✓ {l}")).style(theme::success())
            })
            .chain(match &self.state {
                State::Failed(e) => {
                    vec![
                        Line::from(""),
                        Line::from(format!("  ✗ {e}")).style(theme::error()),
                    ]
                }
                State::Done => {
                    vec![
                        Line::from(""),
                        Line::from("  Installation complete!").style(theme::success()),
                    ]
                }
                _ => vec![],
            })
            .collect();

        let block = Block::default()
            .title(" Log ")
            .title_style(theme::title())
            .borders(Borders::ALL)
            .border_style(theme::border());

        let log_widget = Paragraph::new(log_lines)
            .block(block)
            .wrap(Wrap { trim: false });
        frame.render_widget(log_widget, chunks[1]);

        match self.state {
            State::Done => {
                ui::render_footer(frame, footer, &[("Enter", "Continue")]);
            }
            State::Failed(_) => {
                ui::render_footer(frame, footer, &[("Esc", "Go back"), ("q", "Quit")]);
            }
            _ => {
                ui::render_footer(frame, footer, &[("", "Installing...")]);
            }
        }
    }

    fn handle_key(&mut self, key: KeyEvent, _config: &mut InstallConfig) -> StepAction {
        match &self.state {
            State::Done => match key.code {
                KeyCode::Enter => StepAction::Next,
                _ => StepAction::None,
            },
            State::Failed(_) => match key.code {
                KeyCode::Esc => StepAction::Prev,
                _ => StepAction::None,
            },
            _ => StepAction::None,
        }
    }
}
