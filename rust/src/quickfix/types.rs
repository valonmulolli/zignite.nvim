#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct QuickfixOptions {
    pub max_lines: usize,
    pub max_bytes: usize,
    pub strip_ansi: bool,
    pub strip_max_lines: usize,
    pub parse_diagnostics: bool,
}

impl Default for QuickfixOptions {
    fn default() -> Self {
        Self {
            max_lines: 1000,
            max_bytes: 262_144,
            strip_ansi: true,
            strip_max_lines: 400,
            parse_diagnostics: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TailOutput {
    pub lines: Vec<Vec<u8>>,
    pub truncated: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuickfixResult {
    pub lines: Vec<String>,
    pub truncated: bool,
}

pub fn parse_options(options: &[String]) -> Result<QuickfixOptions, String> {
    let mut parsed = QuickfixOptions::default();
    for option in options {
        if option == "--quickfix" {
            continue;
        }
        if let Some(value) = option.strip_prefix("--max-lines=") {
            parsed.max_lines = parse_nonzero(value, option)?;
        } else if let Some(value) = option.strip_prefix("--max-bytes=") {
            parsed.max_bytes = parse_nonzero(value, option)?;
        } else if let Some(value) = option.strip_prefix("--strip-ansi=") {
            parsed.strip_ansi = parse_bool(value, option)?;
        } else if let Some(value) = option.strip_prefix("--strip-max-lines=") {
            parsed.strip_max_lines = parse_nonzero(value, option)?;
        } else if let Some(value) = option.strip_prefix("--parse-diagnostics=") {
            parsed.parse_diagnostics = parse_bool(value, option)?;
        } else {
            return Err(format!("InvalidQuickfixFlag: {option}"));
        }
    }
    Ok(parsed)
}

pub fn parse_nonzero(value: &str, option: &str) -> Result<usize, String> {
    let parsed = value
        .parse::<usize>()
        .map_err(|_| format!("InvalidQuickfixValue: {option}"))?;
    Ok(parsed.max(1))
}

pub fn parse_bool(value: &str, option: &str) -> Result<bool, String> {
    if value == "1" || value.eq_ignore_ascii_case("true") {
        return Ok(true);
    }
    if value == "0" || value.eq_ignore_ascii_case("false") {
        return Ok(false);
    }
    Err(format!("InvalidQuickfixBoolean: {option}"))
}
