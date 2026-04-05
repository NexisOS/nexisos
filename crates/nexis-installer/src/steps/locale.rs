use crossterm::event::{KeyCode, KeyEvent};
use ratatui::Frame;

use crate::app::InstallConfig;
use crate::steps::{Step, StepAction};
use crate::ui;
use crate::ui::widgets::SelectList;

const LOCALES: &[&str] = &[
    "en_US.UTF-8",
    "en_GB.UTF-8",
    "de_DE.UTF-8",
    "fr_FR.UTF-8",
    "es_ES.UTF-8",
    "it_IT.UTF-8",
    "pt_BR.UTF-8",
    "ja_JP.UTF-8",
    "ko_KR.UTF-8",
    "zh_CN.UTF-8",
    "ru_RU.UTF-8",
    "ar_SA.UTF-8",
    "nl_NL.UTF-8",
    "sv_SE.UTF-8",
    "pl_PL.UTF-8",
];

pub struct LocaleStep {
    list: SelectList,
}

impl LocaleStep {
    pub fn new() -> Self {
        Self {
            list: SelectList::new(LOCALES.iter().map(|s| s.to_string()).collect()),
        }
    }
}

impl Step for LocaleStep {
    fn title(&self) -> &str {
        "Locale"
    }

    fn render(&mut self, frame: &mut Frame, _config: &InstallConfig) {
        let (header, body, footer) = ui::page_layout(frame.area());
        ui::render_header(frame, header, self.title(), 1, 16);
        self.list.render(frame, body, "Select your locale");
        ui::render_footer(
            frame,
            footer,
            &[("↑/↓", "Navigate"), ("Enter", "Select"), ("Esc", "Back")],
        );
    }

    fn handle_key(&mut self, key: KeyEvent, config: &mut InstallConfig) -> StepAction {
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                self.list.prev();
                StepAction::None
            }
            KeyCode::Down | KeyCode::Char('j') => {
                self.list.next();
                StepAction::None
            }
            KeyCode::Enter => {
                config.locale = self.list.selected_value().map(|s| s.to_string());
                StepAction::Next
            }
            KeyCode::Esc => StepAction::Prev,
            _ => StepAction::None,
        }
    }
}
