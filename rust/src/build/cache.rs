use std::collections::HashMap;
use std::time::{Duration, Instant};

const TOOL_CACHE_TTL: Duration = Duration::from_secs(1);
const MAX_CACHED_TOOLS: usize = 256;

#[derive(Debug, Clone, Copy)]
struct CachedAvailability {
    available: bool,
    checked_at: Instant,
}

#[derive(Debug, Default)]
pub(crate) struct CommandCache {
    tools: HashMap<(String, String), CachedAvailability>,
}

impl CommandCache {
    pub(crate) fn available(&mut self, tool: &str, cwd: &str) -> bool {
        let key = (tool.to_owned(), cwd.to_owned());
        let now = Instant::now();
        if let Some(cached) = self.tools.get(&key) {
            if now.duration_since(cached.checked_at) < TOOL_CACHE_TTL {
                return cached.available;
            }
        }
        self.tools.remove(&key);
        let available = crate::tool::executable_available(tool, Some(std::path::Path::new(cwd)));
        self.tools
            .retain(|_, cached| now.duration_since(cached.checked_at) < TOOL_CACHE_TTL);
        if self.tools.len() >= MAX_CACHED_TOOLS {
            if let Some(oldest) = self
                .tools
                .iter()
                .min_by_key(|(_, cached)| cached.checked_at)
                .map(|(key, _)| key.clone())
            {
                self.tools.remove(&oldest);
            }
        }
        self.tools.insert(
            key,
            CachedAvailability {
                available,
                checked_at: now,
            },
        );
        available
    }
}

#[cfg(test)]
mod tests {
    use super::CommandCache;

    #[cfg(unix)]
    #[test]
    fn cached_missing_tool_is_rechecked_after_expiry() {
        use std::fs;
        use std::os::unix::fs::PermissionsExt;
        use std::time::Duration;

        let root = std::env::temp_dir().join(format!("zignite-tool-cache-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("create tool directory");
        let executable = root.join("tool");
        let cwd = root.to_string_lossy().into_owned();
        let mut cache = CommandCache::default();

        assert!(!cache.available("./tool", &cwd));
        fs::write(&executable, "#!/bin/sh\nexit 0\n").expect("create executable");
        let mut permissions = fs::metadata(&executable)
            .expect("executable metadata")
            .permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&executable, permissions).expect("make executable");

        std::thread::sleep(Duration::from_millis(1_050));
        assert!(cache.available("./tool", &cwd));
        fs::remove_dir_all(root).expect("remove tool directory");
    }
}
