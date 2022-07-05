const std = @import("std");
const Runner = @import("./datadriven.zig").Runner;

const InstructionType = enum {
    adc,
    and_ins,
    asl,
    bit,
    sta,
    stx,
    // Branch Ops
    bpl,
    bmi,
    bvc,
    bvs,
    bcc,
    bcs,
    bne,
    beq,

    lda,
    ldx,
    tax,
    txa,
    tay,
    tya,
    inx,
    brk,
    dex,
    cpx,

    cmp,
};

pub fn main() anyerror!void {
    std.log.info("All your codebase are belong to us.", .{});
}

test "basic test" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var arena_alloc = arena.allocator();

    var runner = try Runner.load("testdata/t", arena_alloc);
    defer runner.finish() catch |err| {
        std.debug.print("error: {s}\n", .{err});
    };

    while (try runner.next()) |test_case| {
        if (std.mem.eql(u8, test_case.directive.command, "single")) {
            try runner.result(test_case.input);
        } else if (std.mem.eql(u8, test_case.directive.command, "double")) {
            // The whole arena will be deallocated at the end.
            var out = std.ArrayList(u8).init(arena_alloc);
            defer out.deinit();
            for (test_case.input) |ch| {
                if (ch != '\n') {
                    try out.append(ch);
                }
            }
            for (test_case.input) |ch| {
                if (ch != '\n') {
                    try out.append(ch);
                }
            }
            try out.append('\n');
            try runner.result(out.items);
        } else {
            try runner.err("invalid directive");
        }
    }
}
