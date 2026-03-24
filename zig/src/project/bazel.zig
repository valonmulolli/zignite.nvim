const model = @import("bazel/model.zig");
const infer = @import("bazel/infer.zig");
const parse = @import("bazel/parse.zig");
const workspace = @import("bazel/workspace.zig");

pub const Target = model.Target;
pub const CommandEntry = model.CommandEntry;
pub const CommandInfo = model.CommandInfo;

pub const freeOwnedTargets = model.freeOwnedTargets;
pub const freeOwnedCommandInfo = model.freeOwnedCommandInfo;
pub const parseTargets = parse.parseTargets;
pub const buildCommandInfo = infer.buildCommandInfo;
pub const buildWorkspaceCommandInfo = workspace.buildWorkspaceCommandInfo;
