use crossterm::event::{KeyCode, KeyEvent};
use ratatui::{
    layout::{Constraint, Direction, Layout},
    text::Line,
    widgets::Paragraph,
    Frame,
};

use crate::app::{InstallConfig, NetworkConfig};
use crate::steps::{Step, StepAction};
use crate::system::network as netops;
use crate::theme;
use crate::ui;
use crate::ui::widgets::SelectList;

enum Phase {
    InterfaceSelect,
    Connected,
    NoInterfaces,
}

pub struct NetworkStep {
    list: SelectList,
    interfaces: Vec<netops::NetInterface>,
    phase: Phase,
    status_msg: String,
}

impl NetworkStep {
    pub fn new() -> Self {
        Self {
            list: SelectList::new(vec!["Detecting...".to_string()]),
            interfaces: Vec::new(),
            phase: Phase::InterfaceSelect,
            status_msg: String::new(),
        }
    }

    fn refresh_interfaces(&mut self) {
        match netops::list_interfaces() {
            Ok(ifaces) if !ifaces.is_empty() => {
                let names: Vec<String> = ifaces
                    .iter()
                    .map(|i| {
                        let kind = if i.is_wireless { "wifi" } else { "eth" };
                        let state = if i.is_up { "up" } else { "down" };
                        format!("{} ({}, {})", i.name, kind, state)
                    })
                    .collect();
                self.list = SelectList::new(names);
                self.interfaces = ifaces;
                self.phase = Phase::InterfaceSelect;

                // If already online, skip ahead.
                if netops::check_connectivity() {
                    self.phase = Phase::Connected;
                    self.status_msg = "Network is already connected.".to_string();
                }
            }
            Ok(_) => {
                self.phase = Phase::NoInterfaces;
                self.list = SelectList::new(vec!["No interfaces found".to_string()]);
            }
            Err(e) => {
                self.phase = Phase::NoInterfaces;
                self.status_msg = format!("Error: {e}");
            }
        }
    }
}

impl Step for NetworkStep {
    fn title(&self) -> &str {
        "Network"
    }

    fn on_enter(&mut self, _config: &InstallConfig) {
        self.refresh_interfaces();
    }

    fn render(&mut self, frame: &mut Frame, _config: &InstallConfig) {
        let (header, body, footer) = ui::page_layout(frame.area());
        ui::render_header(frame, header, self.title(), 3, 16);

        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Min(1), Constraint::Length(3)])
            .split(body);

        match self.phase {
            Phase::InterfaceSelect => {
                self.list.render(frame, chunks[0], "Select network interface");
            }
            Phase::Connected => {
                ui::widgets::render_info(
                    frame,
                    chunks[0],
                    "Network",
                    &[&self.status_msg, "", "Press Enter to continue."],
                );
            }
            Phase::NoInterfaces => {
                ui::widgets::render_info(
                    frame,
                    chunks[0],
                    "Network",
                    &[
                        "No network interfaces detected.",
                        "You can continue without network for an offline install.",
                        "",
                        "Press Enter to skip or Esc to go back.",
                    ],
                );
            }
        }

        if !self.status_msg.is_empty() {
            let msg = Paragraph::new(Line::from(self.status_msg.as_str()))
                .style(theme::muted());
            frame.render_widget(msg, chunks[1]);
        }

        ui::render_footer(
            frame,
            footer,
            &[
                ("↑/↓", "Navigate"),
                ("Enter", "Select/Skip"),
                ("Esc", "Back"),
            ],
        );
    }

    fn handle_key(&mut self, key: KeyEvent, config: &mut InstallConfig) -> StepAction {
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => { self.list.prev(); StepAction::None }
            KeyCode::Down | KeyCode::Char('j') => { self.list.next(); StepAction::None }
            KeyCode::Enter => {
                match self.phase {
                    Phase::Connected | Phase::NoInterfaces => StepAction::Next,
                    Phase::InterfaceSelect => {
                        if let Some(idx) = self.list.selected_index() {
                            if let Some(iface) = self.interfaces.get(idx) {
                                let name = iface.name.clone();
                                config.network = Some(NetworkConfig {
                                    interface: name.clone(),
                                    use_dhcp: true,
                                    ..Default::default()
                                });
                                match netops::dhcp_up(&name) {
                                    Ok(_) => {
                                        self.status_msg = format!("Connected via {name}");
                                        self.phase = Phase::Connected;
                                    }
                                    Err(e) => {
                                        self.status_msg = format!("DHCP failed: {e}");
                                    }
                                }
                            }
                        }
                        StepAction::None
                    }
                }
            }
            KeyCode::Esc => StepAction::Prev,
            _ => StepAction::None,
        }
    }
}
