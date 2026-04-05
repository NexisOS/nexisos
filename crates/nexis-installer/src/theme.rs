use ratatui::style::{Color, Modifier, Style};

// NexisOS installer palette — tuned for 256-color VT.
// Override the VT's base 16 colors with `setvtrgb` at boot for exact brand match.

pub const BG: Color = Color::Indexed(235);          // dark background
pub const FG: Color = Color::Indexed(252);           // light foreground
pub const ACCENT: Color = Color::Indexed(75);        // bright blue accent
pub const ACCENT_DIM: Color = Color::Indexed(67);    // muted blue
pub const SUCCESS: Color = Color::Indexed(114);      // green
pub const WARNING: Color = Color::Indexed(214);      // amber
pub const ERROR: Color = Color::Indexed(203);        // red
pub const MUTED: Color = Color::Indexed(245);        // gray for secondary text
pub const HIGHLIGHT_BG: Color = Color::Indexed(238); // selected row bg
pub const BORDER: Color = Color::Indexed(240);       // border lines

pub fn base() -> Style {
    Style::default().fg(FG).bg(BG)
}

pub fn title() -> Style {
    Style::default().fg(ACCENT).add_modifier(Modifier::BOLD)
}

pub fn selected() -> Style {
    Style::default()
        .fg(ACCENT)
        .bg(HIGHLIGHT_BG)
        .add_modifier(Modifier::BOLD)
}

pub fn unselected() -> Style {
    Style::default().fg(FG)
}

pub fn muted() -> Style {
    Style::default().fg(MUTED)
}

pub fn input_active() -> Style {
    Style::default().fg(FG).bg(HIGHLIGHT_BG)
}

pub fn input_inactive() -> Style {
    Style::default().fg(MUTED).bg(BG)
}

pub fn error() -> Style {
    Style::default().fg(ERROR).add_modifier(Modifier::BOLD)
}

pub fn success() -> Style {
    Style::default().fg(SUCCESS)
}

pub fn warning() -> Style {
    Style::default().fg(WARNING)
}

pub fn progress_bar() -> Style {
    Style::default().fg(ACCENT)
}

pub fn progress_bar_bg() -> Style {
    Style::default().fg(HIGHLIGHT_BG)
}

pub fn keybind() -> Style {
    Style::default().fg(ACCENT_DIM)
}

pub fn border() -> Style {
    Style::default().fg(BORDER)
}
