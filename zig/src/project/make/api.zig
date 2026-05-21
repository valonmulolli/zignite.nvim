const parse = @import("parse.zig");

pub const marker_names: []const []const u8 = &.{ "Makefile", "makefile", "GNUmakefile" };
pub const collectReferencedFilesFromFileAlloc = parse.collectReferencedFilesFromFileAlloc;
pub const collectReferencedFilesFromFileAllocWithIO = parse.collectReferencedFilesFromFileAllocWithIO;
pub const parseTargets = parse.parseTargets;
pub const parseTargetsFromFileAlloc = parse.parseTargetsFromFileAlloc;
pub const parseTargetsFromFileAllocWithIO = parse.parseTargetsFromFileAllocWithIO;
