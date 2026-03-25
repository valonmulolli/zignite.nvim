const parse = @import("parse.zig");

pub const detectPackageManager = parse.detectPackageManager;
pub const formatScriptCommandAlloc = parse.formatScriptCommandAlloc;
pub const formatInstallCommandAlloc = parse.formatInstallCommandAlloc;
pub const parseScripts = parse.parseScripts;
pub const selectLiveScriptName = parse.selectLiveScriptName;
