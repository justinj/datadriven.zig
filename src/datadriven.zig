const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const ItemTag = enum {
    blank_line,
    comment,
    test_case,
};
const Item = union(ItemTag) {
    blank_line: u0,
    comment: []const u8,
    test_case: TestCase,
};

const DatadrivenError = error{
    ParseError,
    UnprocessedTest,
    NoActiveTest,
    FileCompleted,
    Error,
};

const TestCase = struct {
    directive: Directive,
    input: []const u8,
    output: []const u8,

    pub fn format(
        self: TestCase,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("{s}\n{s}----\n{s}", .{ self.directive, self.input, self.output });
    }
};

const Directive = struct {
    command: []const u8,
    arguments: []Argument,

    pub fn format(
        self: Directive,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("{s}", .{self.command});
        for (self.arguments) |arg| {
            try writer.print(" {s}", .{arg});
        }
    }
};

const Argument = struct {
    name: []const u8,
    values: [][]const u8,

    pub fn format(
        self: Argument,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("{s}", .{self.name});
        if (self.values.len > 0) {
            try writer.print("=", .{});
        }
        if (self.values.len > 1) {
            try writer.print("(", .{});
        }
        for (self.values) |arg, i| {
            if (i > 0) {
                try writer.print(",", .{});
            }
            try writer.print("{s}", .{arg});
        }
        if (self.values.len > 1) {
            try writer.print(")", .{});
        }
    }
};

const Parser = struct {
    alloc: Allocator,
    input: []const u8,
    idx: u64,

    fn new(alloc: Allocator, input: []const u8) Parser {
        return Parser{
            .alloc = alloc,
            .input = input,
            .idx = 0,
        };
    }

    fn peek(self: Parser) ?u8 {
        if (self.idx < self.input.len) {
            return self.input[self.idx];
        } else {
            return null;
        }
    }

    fn eat(self: *Parser, ch: u8) bool {
        if (self.idx < self.input.len and self.input[self.idx] == ch) {
            self.idx += 1;
            return true;
        }
        return false;
    }

    fn munch(self: *Parser) void {
        while (self.idx < self.input.len and isSpace(self.input[self.idx])) : (self.idx += 1) {}
    }

    fn parseWord(self: *Parser) ![]const u8 {
        var start = self.idx;
        var i = self.idx;
        if (!isWord(self.input[i])) {
            return DatadrivenError.ParseError;
        }
        while (i < self.input.len and isWord(self.input[i])) : (i += 1) {}
        self.idx = i;
        return self.input[start..i];
    }

    fn parseArg(self: *Parser) !Argument {
        var arg_name = try self.parseWord();
        self.munch();

        var values = ArrayList([]const u8).init(self.alloc);

        if (self.eat('=')) {
            self.munch();
            var parens = self.eat('(');
            while (isWord(self.peek() orelse 0)) {
                try values.append(try self.parseWord());
                self.munch();
                if (!parens) {
                    break;
                }
                switch (self.peek() orelse 0) {
                    ')' => {
                        if (!parens) {
                            return DatadrivenError.ParseError;
                        }
                        self.idx += 1;
                        parens = false;
                        break;
                    },
                    ',' => {
                        self.idx += 1;
                        self.munch();
                    },
                    else => {},
                }
            }
            if (parens) {
                return DatadrivenError.ParseError;
            }
        }

        return Argument{
            .name = arg_name,
            .values = values.toOwnedSlice(),
        };
    }

    fn parseDirective(self: *Parser) !Directive {
        self.munch();
        var command = try self.parseWord();
        self.munch();
        var arguments = ArrayList(Argument).init(self.alloc);

        while (self.peek() orelse '\n' != '\n') {
            try arguments.append(try self.parseArg());
            self.munch();
        }

        return Directive{
            .command = command,
            .arguments = arguments.toOwnedSlice(),
        };
    }

    fn nextLine(self: *Parser) ?[]const u8 {
        if (self.idx >= self.input.len) {
            return null;
        }
        var line_start = self.idx;
        while (self.idx < self.input.len and self.input[self.idx] != '\n') : (self.idx += 1) {}
        // skip over the \n.
        if (self.idx < self.input.len and self.input[self.idx] == '\n') {
            self.idx += 1;
        }
        return self.input[line_start .. self.idx - 1];
    }

    fn parseTestCase(self: *Parser) !TestCase {
        var directive = try self.parseDirective();
        errdefer directive.deinit(self.alloc);

        self.idx += 1;

        var inputStart = self.idx;
        var inputEnd = self.idx;
        var line = self.nextLine() orelse "";
        while (!std.mem.eql(u8, line, "----")) {
            inputEnd = self.idx;
            line = self.nextLine() orelse break;
        }

        // Skip over the ----
        var outputStart = self.idx;
        var outputEnd = self.idx;
        line = self.nextLine() orelse "";
        while (!std.mem.eql(u8, line, "")) {
            outputEnd = self.idx;
            line = self.nextLine() orelse break;
        }

        return TestCase{
            .directive = directive,
            .input = self.input[inputStart..inputEnd],
            .output = self.input[outputStart..outputEnd],
        };
    }

    fn nextItem(self: *Parser) !?Item {
        // Find the next nonspace character
        var i = self.idx;
        while (i < self.input.len and isSpace(self.input[i])) : (i += 1) {}
        if (i >= self.input.len) {
            return null;
        }
        switch (self.input[i]) {
            '\n' => {
                self.idx = i + 1;
                return Item{ .blank_line = 0 };
            },
            '#' => {
                var start = self.idx;
                self.idx = i + 1;
                while (self.idx < self.input.len and self.input[self.idx] != '\n') : (self.idx += 1) {}
                return Item{ .comment = self.input[start..self.idx] };
            },
            else => {
                return Item{ .test_case = try self.parseTestCase() };
            },
        }
    }
};

// TODO: there must be a better way to do this? but the json parser in the
// stdlib does approx. this.
fn isSpace(ch: u8) bool {
    switch (ch) {
        '\t', ' ', 0x00 => {
            return true;
        },
        else => {
            return false;
        },
    }
}

fn isWord(ch: u8) bool {
    switch (ch) {
        '\t', ' ', 0x00, ',', '=', '\n', '(', ')' => {
            return false;
        },
        else => {
            return true;
        },
    }
}

test "test parsing directives" {
    const Case = struct {
        input: []const u8,
        output: ?[]const u8,
    };

    var allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer allocator.deinit();
    var alloc = allocator.allocator();

    const cases = [_]Case{
        Case{ .input = "hello", .output = "hello" },
        Case{ .input = "hello world", .output = "hello world" },
        Case{ .input = "hello   world", .output = "hello world" },
        Case{ .input = "hello foo = bar", .output = "hello foo=bar" },
        Case{ .input = "hello foo = (bar)", .output = "hello foo=bar" },
        Case{ .input = "hello foo=(bar,baz)", .output = "hello foo=(bar,baz)" },
        Case{ .input = "hello foo=(bar,baz)", .output = "hello foo=(bar,baz)" },
        Case{ .input = "hello foo=(bar, baz)", .output = "hello foo=(bar,baz)" },
        Case{ .input = "hello foo=(bar, baz) banana=apple", .output = "hello foo=(bar,baz) banana=apple" },

        Case{ .input = "hello foo=bar,baz", .output = null },
        Case{ .input = "hello foo=(bar,baz", .output = null },
        Case{ .input = "hello foo=bar,baz)", .output = null },
        Case{ .input = "hello foo=bar baz)", .output = null },
    };

    for (cases) |case| {
        var parser = Parser.new(alloc, case.input);

        var dir: Directive = parser.parseDirective() catch {
            // Parse error: the expectation should be null.
            try std.testing.expectEqual(case.output, null);
            continue;
        };

        if (case.output) |output| {
            var formatted = try std.fmt.allocPrint(alloc, "{s}", .{dir});
            defer alloc.free(formatted);

            std.testing.expect(std.mem.eql(u8, output, formatted)) catch {
                std.debug.print("expected equal:\n  {s}\n  {s}\n", .{ output, formatted });
                try std.testing.expect(false);
            };
        } else {
            std.debug.print("shouldn't have parsed, but it did", .{});
            try std.testing.expect(false);
        }
    }
}

test "test parsing entire test cases" {
    const Case = struct {
        input: []const u8,
        output: ?[]const u8,
    };

    var allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer allocator.deinit();
    var alloc = allocator.allocator();

    const cases = [_]Case{
        Case{ .input = "hello\n----\n", .output = "hello\n----\n" },
        Case{ .input = "hello\ninput\n----\n", .output = "hello\ninput\n----\n" },
        Case{ .input = "hello\ninput\ninput line 2\n----\n", .output = "hello\ninput\ninput line 2\n----\n" },
        Case{ .input = "hello\ninput\n----\noutput\n", .output = "hello\ninput\n----\noutput\n" },
        Case{ .input = "hello\ninput\n----\noutput\noutput line 2\n\nfoo\n", .output = "hello\ninput\n----\noutput\noutput line 2\n" },
    };

    for (cases) |case| {
        var parser = Parser.new(alloc, case.input);

        var dir = parser.parseTestCase() catch {
            // Parse error: the expectation should be null.
            try std.testing.expectEqual(case.output, null);
            continue;
        };

        if (case.output) |output| {
            var formatted = try std.fmt.allocPrint(alloc, "{s}", .{dir});
            defer alloc.free(formatted);

            std.testing.expect(std.mem.eql(u8, output, formatted)) catch {
                std.debug.print("expected equal:\n```\n{s}```\n{s}```\n", .{ output, formatted });
                try std.testing.expect(false);
            };
        } else {
            std.debug.print("shouldn't have parsed, but it did", .{});
            try std.testing.expect(false);
        }
    }
}

const RunnerStateTag = enum {
    pending,
    running_test,
    completed,
};
const RunnerState = union(RunnerStateTag) {
    pending: u0,
    running_test: TestCase,
    completed: u0,
};

pub const Runner = struct {
    input_filename: []const u8,
    parser: Parser,
    state: RunnerState,
    output_buf: ?ArrayList(u8),

    pub fn load(filename: []const u8, allocator: Allocator) !Runner {
        var file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();

        var full_file = ArrayList(u8).init(allocator);
        var buf_reader = std.io.bufferedReader(file.reader());
        var in_stream = buf_reader.reader();
        try in_stream.readAllArrayList(&full_file, std.math.maxInt(usize));

        var parser = Parser.new(allocator, full_file.toOwnedSlice());

        var output_buf: ?ArrayList(u8) = null;
        if (std.os.getenv("REWRITE") != null) {
            output_buf = ArrayList(u8).init(allocator);
        }

        return Runner{
            .input_filename = filename,
            .parser = parser,
            .state = RunnerState.pending,
            .output_buf = output_buf,
        };
    }

    pub fn next(self: *Runner) !?TestCase {
        switch (self.state) {
            .running_test => {
                return DatadrivenError.UnprocessedTest;
            },
            .completed => {
                return DatadrivenError.FileCompleted;
            },
            else => {},
        }
        while (try self.parser.nextItem()) |item| {
            switch (item) {
                ItemTag.test_case => |test_case| {
                    if (self.output_buf) |*buf| {
                        try test_case.directive.format("{s}", .{}, buf.writer());
                        try buf.append('\n');
                        try buf.appendSlice(test_case.input);
                        try buf.appendSlice("----\n");
                    }
                    self.state = RunnerState{ .running_test = test_case };
                    return test_case;
                },
                ItemTag.blank_line => {
                    if (self.output_buf) |*buf| {
                        try buf.append('\n');
                    }
                },
                ItemTag.comment => |comment| {
                    if (self.output_buf) |*buf| {
                        try buf.appendSlice(comment);
                    }
                },
            }
        }
        self.state = RunnerState{ .completed = 0 };
        return null;
    }

    pub fn result(self: *Runner, v: []const u8) !void {
        switch (self.state) {
            .pending => {
                return DatadrivenError.NoActiveTest;
            },
            .completed => {
                return DatadrivenError.FileCompleted;
            },
            .running_test => |case| {
                if (self.output_buf) |*buf| {
                    try buf.appendSlice(v);
                    try buf.append('\n');
                } else {
                    if (!std.mem.eql(u8, v, case.output)) {
                        std.debug.print(
                            "FAILURE:\nEXPECTED:\n{s}\n\nACTUAL:\n{s}\n",
                            .{
                                case.output,
                                v,
                            },
                        );
                    }
                }
                self.state = RunnerState{ .pending = 0 };
            },
        }
    }

    pub fn err(self: *Runner, v: []const u8) !void {
        switch (self.state) {
            .pending => {
                return DatadrivenError.NoActiveTest;
            },
            .completed => {
                return DatadrivenError.FileCompleted;
            },
            .running_test => {
                std.debug.print("{s}\n", .{v});
                return DatadrivenError.Error;
            },
        }
        self.state = RunnerState{ .pending = 0 };
    }

    pub fn finish(self: Runner) !void {
        // Now attempt to overwrite the old one.
        if (self.output_buf) |*buf| {
            var file = try std.fs.cwd().createFile(self.input_filename, .{
                .truncate = true,
            });
            // Truncate the file.
            try file.setEndPos(0);
            defer file.close();
            try file.writeAll(buf.items);
        }
    }
};

test "test parsing entire file" {
    const Case = struct {
        input: []const u8,
        output: ?[]const u8,
    };

    var allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer allocator.deinit();
    var alloc = allocator.allocator();

    const cases = [_]Case{
        Case{ .input = 
        \\# foo bar
        \\
        \\hello
        \\input
        \\----
        \\output
        , .output = 
        \\# foo bar
        \\
        \\hello
        \\input
        \\----
        \\output
        },
        // Case{ .input = "hello\ninput\n----\n", .output = "hello\ninput\n----\n" },
        // Case{ .input = "hello\ninput\ninput line 2\n----\n", .output = "hello\ninput\ninput line 2\n----\n" },
        // Case{ .input = "hello\ninput\n----\noutput\n", .output = "hello\ninput\n----\noutput\n" },
        // Case{ .input = "hello\ninput\n----\noutput\noutput line 2\n\n", .output = "hello\ninput\n----\noutput\noutput line 2\n" },
    };

    for (cases) |case| {
        var parser = Parser.new(alloc, case.input);

        var dir = parser.parseTestCase() catch {
            // Parse error: the expectation should be null.
            try std.testing.expectEqual(case.output, null);
            continue;
        };

        if (case.output) |output| {
            var formatted = try std.fmt.allocPrint(alloc, "{s}", .{dir});
            defer alloc.free(formatted);

            std.testing.expect(std.mem.eql(u8, output, formatted)) catch {
                std.debug.print("expected equal:\n```\n{s}```\n{s}```\n", .{ output, formatted });
                try std.testing.expect(false);
            };
        } else {
            std.debug.print("shouldn't have parsed, but it did", .{});
            try std.testing.expect(false);
        }
    }
}
