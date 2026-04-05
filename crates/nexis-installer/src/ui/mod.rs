pub mod widgets;

use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::Stylize,
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph},
    Frame,
};

use crate::theme;

/// Standard page layout: header, body, footer.
pub fn page_layout(area: Rect) -> (Rect, Rect, Rect) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),  // header
            Constraint::Min(1),    // body
            Constraint::Length(3), // footer
        ])
        .split(area);
    (chunks[0], chunks[1], chunks[2])
}

/// Center a fixed-size area within a parent.
pub fn centered(area: Rect, width: u16, height: u16) -> Rect {
    let vert = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length((area.height.saturating_sub(height)) / 2),
            Constraint::Length(height),
            Constraint::Min(0),
        ])
        .split(area);
    Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Length((area.width.saturating_sub(width)) / 2),
            Constraint::Length(width),
            Constraint::Min(0),
        ])
        .split(vert[1])[1]
}

/// Draw the installer header bar with step title and progress.
pub fn render_header(frame: &mut Frame, area: Rect, title: &str, step: usize, total: usize) {
    let progress = format!("[{}/{}]", step + 1, total);
    let header_text = Line::from(vec![
        Span::styled(" NexisOS Installer ", theme::title()),
        Span::styled("─ ", theme::border()),
        Span::styled(title, theme::base().bold()),
        Span::raw(" "),
        Span::styled(progress, theme::muted()),
    ]);
    let block = Block::default()
        .borders(Borders::BOTTOM)
        .border_style(theme::border());
    let header = Paragraph::new(header_text).block(block);
    frame.render_widget(header, area);
}

/// Draw the footer with navigation hints.
pub fn render_footer(frame: &mut Frame, area: Rect, hints: &[(&str, &str)]) {
    let spans: Vec<Span> = hints
        .iter()
        .enumerate()
        .flat_map(|(i, (key, desc))| {
            let mut v = vec![
                Span::styled(format!(" {key} "), theme::keybind()),
                Span::styled(*desc, theme::muted()),
            ];
            if i + 1 < hints.len() {
                v.push(Span::raw("  │  "));
            }
            v
        })
        .collect();
    let block = Block::default()
        .borders(Borders::TOP)
        .border_style(theme::border());
    let footer = Paragraph::new(Line::from(spans)).block(block);
    frame.render_widget(footer, area);
}
