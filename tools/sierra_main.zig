//! Generic Sierra benchmark entry point.
//! Consumers provide their benchmark module as `sierra_root`.
const std = @import("std");
const sierra = @import("sierra");
const root = @import("sierra_root");

pub fn main(init: std.process.Init) !u8 {
    return sierra.runModule(root, init);
}
