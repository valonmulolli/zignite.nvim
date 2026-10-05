use std::collections::HashMap;

#[derive(Debug, Default)]
pub(crate) struct CommandCache {
    tools: HashMap<(String, String), bool>,
}

impl CommandCache {
    pub(crate) fn available(&mut self, tool: &str, cwd: &str) -> bool {
        let key = (tool.to_owned(), cwd.to_owned());
        if let Some(available) = self.tools.get(&key) {
            return *available;
        }
        let available = std::process::Command::new(tool)
            .current_dir(cwd)
            .arg("--version")
            .output()
            .is_ok();
        self.tools.insert(key, available);
        available
    }
}
