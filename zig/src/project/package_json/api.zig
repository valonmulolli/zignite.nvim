const parse = @import("parse.zig");

pub const detectPackageManager = parse.detectPackageManager;
pub const detectPackageManagerWithIO = parse.detectPackageManagerWithIO;
pub const formatScriptCommandAlloc = parse.formatScriptCommandAlloc;
pub const formatInstallCommandAlloc = parse.formatInstallCommandAlloc;
pub const parseScripts = parse.parseScripts;
pub const parseScriptsLenient = parse.parseScriptsLenient;
pub const selectLiveScriptName = parse.selectLiveScriptName;
