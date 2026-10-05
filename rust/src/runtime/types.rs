use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunnerSource {
    Config,
    Project,
    Builtin,
    Filetype,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedRunner {
    pub source: RunnerSource,
    pub filetype: String,
    pub execution_path: Option<String>,
    pub command: Option<String>,
    pub argv: Vec<String>,
    pub cleanup_command: Option<String>,
    pub cwd: Option<String>,
    pub name: Option<String>,
    pub missing_tool: Option<String>,
    pub timeout: Option<Duration>,
}

impl Default for ResolvedRunner {
    fn default() -> Self {
        Self {
            source: RunnerSource::Filetype,
            filetype: String::new(),
            execution_path: None,
            command: None,
            argv: Vec::new(),
            cleanup_command: None,
            cwd: None,
            name: None,
            missing_tool: None,
            timeout: None,
        }
    }
}
