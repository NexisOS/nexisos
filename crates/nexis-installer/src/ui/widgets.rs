use ratatui::{
    layout::Rect,
    style::Stylize,
    text::{Line, Span},
    widgets::{Block, Borders, Gauge, List, ListItem, ListState, Paragraph},
    Frame,
};

use crate::theme;

// ── Selectable list ──────────────────────────────────────────────────────────

pub struct SelectList {
    pub items: Vec<String>,
    pub state: ListState,
}

impl SelectList {
    pub fn new(items: Vec<String>) -> Self {
        let mut state = ListState::default();
        if !items.is_empty() {
            state.select(Some(0));
        }
        Self { items, state }
    }

    pub fn selected_index(&self) -> Option<usize> {
        self.state.selected()
    }

    pub fn selected_value(&self) -> Option<&str> {
        self.state.selected().map(|i| self.items[i].as_str())
    }

    pub fn next(&mut self) {
        if self.items.is_empty() {
            return;
        }
        let i = self.state.selected().unwrap_or(0);
        self.state.select(Some((i + 1) % self.items.len()));
    }

    pub fn prev(&mut self) {
        if self.items.is_empty() {
            return;
        }
        let i = self.state.selected().unwrap_or(0);
        self.state
            .select(Some(i.checked_sub(1).unwrap_or(self.items.len() - 1)));
    }

    pub fn render(&mut self, frame: &mut Frame, area: Rect, title: &str) {
        let items: Vec<ListItem> = self
            .items
            .iter()
            .enumerate()
            .map(|(i, item)| {
                let style = if Some(i) == self.state.selected() {
                    theme::selected()
                } else {
                    theme::unselected()
                };
                let marker = if Some(i) == self.state.selected() {
                    "▸ "
                } else {
                    "  "
                };
                ListItem::new(Line::from(vec![
                    Span::styled(marker, style),
                    Span::styled(item.as_str(), style),
                ]))
            })
            .collect();

        let block = Block::default()
            .title(format!(" {title} "))
            .title_style(theme::title())
            .borders(Borders::ALL)
            .border_style(theme::border());

        let list = List::new(items).block(block);
        frame.render_stateful_widget(list, area, &mut self.state);
    }
}

// ── Text input ───────────────────────────────────────────────────────────────

pub struct TextInput {
    pub value: String,
    pub label: String,
    pub cursor: usize,
    pub masked: bool,
}

impl TextInput {
    pub fn new(label: impl Into<String>) -> Self {
        Self {
            value: String::new(),
            label: label.into(),
            cursor: 0,
            masked: false,
        }
    }

    pub fn password(label: impl Into<String>) -> Self {
        Self {
            value: String::new(),
            label: label.into(),
            cursor: 0,
            masked: true,
        }
    }

    pub fn insert(&mut self, ch: char) {
        self.value.insert(self.cursor, ch);
        self.cursor += ch.len_utf8();
    }

    pub fn backspace(&mut self) {
        if self.cursor > 0 {
            let prev = self.value[..self.cursor]
                .char_indices()
                .last()
                .map(|(i, _)| i)
                .unwrap_or(0);
            self.value.remove(prev);
            self.cursor = prev;
        }
    }

    pub fn delete(&mut self) {
        if self.cursor < self.value.len() {
            self.value.remove(self.cursor);
        }
    }

    pub fn move_left(&mut self) {
        if self.cursor > 0 {
            self.cursor = self.value[..self.cursor]
                .char_indices()
                .last()
                .map(|(i, _)| i)
                .unwrap_or(0);
        }
    }

    pub fn move_right(&mut self) {
        if self.cursor < self.value.len() {
            self.cursor += self.value[self.cursor..].chars().next().map_or(0, |c| c.len_utf8());
        }
    }

    pub fn render(&self, frame: &mut Frame, area: Rect, active: bool) {
        let display = if self.masked {
            "●".repeat(self.value.chars().count())
        } else {
            self.value.clone()
        };

        let style = if active {
            theme::input_active()
        } else {
            theme::input_inactive()
        };

        let block = Block::default()
            .title(format!(" {} ", self.label))
            .title_style(if active { theme::title() } else { theme::muted() })
            .borders(Borders::ALL)
            .border_style(if active { theme::title() } else { theme::border() });

        let paragraph = Paragraph::new(display).style(style).block(block);
        frame.render_widget(paragraph, area);

        // Show cursor.
        if active {
            let cursor_x = area.x + 1 + self.value[..self.cursor].chars().count() as u16;
            let cursor_y = area.y + 1;
            frame.set_cursor_position((cursor_x, cursor_y));
        }
    }
}

// ── Toggle / checkbox ────────────────────────────────────────────────────────

pub struct Toggle {
    pub label: String,
    pub enabled: bool,
}

impl Toggle {
    pub fn new(label: impl Into<String>, default: bool) -> Self {
        Self {
            label: label.into(),
            enabled: default,
        }
    }

    pub fn toggle(&mut self) {
        self.enabled = !self.enabled;
    }

    pub fn render(&self, frame: &mut Frame, area: Rect, active: bool) {
        let icon = if self.enabled { "[■]" } else { "[ ]" };
        let style = if active {
            theme::selected()
        } else {
            theme::unselected()
        };
        let line = Line::from(vec![
            Span::styled(format!("{icon} "), style),
            Span::styled(self.label.as_str(), style),
        ]);
        frame.render_widget(Paragraph::new(line), area);
    }
}

// ── Progress bar ─────────────────────────────────────────────────────────────

pub fn render_progress(frame: &mut Frame, area: Rect, label: &str, ratio: f64) {
    let block = Block::default()
        .title(format!(" {label} "))
        .title_style(theme::title())
        .borders(Borders::ALL)
        .border_style(theme::border());

    let gauge = Gauge::default()
        .block(block)
        .gauge_style(theme::progress_bar().on_dark_gray())
        .ratio(ratio.clamp(0.0, 1.0))
        .label(format!("{:.0}%", ratio * 100.0));

    frame.render_widget(gauge, area);
}

// ── Info paragraph ───────────────────────────────────────────────────────────

pub fn render_info(frame: &mut Frame, area: Rect, title: &str, lines: &[&str]) {
    let text: Vec<Line> = lines.iter().map(|l| Line::from(*l)).collect();
    let block = Block::default()
        .title(format!(" {title} "))
        .title_style(theme::title())
        .borders(Borders::ALL)
        .border_style(theme::border());
    let paragraph = Paragraph::new(text)
        .style(theme::base())
        .block(block)
        .wrap(ratatui::widgets::Wrap { trim: true });
    frame.render_widget(paragraph, area);
}
