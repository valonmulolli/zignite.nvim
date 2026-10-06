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
        let available = crate::tool::executable_available(tool, Some(std::path::Path::new(cwd)));
        self.tools.insert(key, available);
        available
    }
}
