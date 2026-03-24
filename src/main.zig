const std = @import("std");
const posix = std.posix;
const fs = std.fs;
const mem = std.mem;
const process = std.process;

// ── Stderr output helpers ────────────────────────────────────────────────────
// Use raw posix.write to stderr (fd=2) to avoid buffered writer complexity.

fn stderrWrite(msg: []const u8) void {
    _ = posix.write(posix.STDERR_FILENO, msg) catch {};
}

fn stderrPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    stderrWrite(msg);
}

// ── Colors ───────────────────────────────────────────────────────────────────

var use_color: bool = false;

fn initColor() void {
    use_color = fs.File.stderr().isTty();
}

fn bold() []const u8 {
    return if (use_color) "\x1b[1m" else "";
}
fn dim() []const u8 {
    return if (use_color) "\x1b[2m" else "";
}
fn red() []const u8 {
    return if (use_color) "\x1b[31m" else "";
}
fn green() []const u8 {
    return if (use_color) "\x1b[32m" else "";
}
fn yellow() []const u8 {
    return if (use_color) "\x1b[33m" else "";
}
fn cyan() []const u8 {
    return if (use_color) "\x1b[36m" else "";
}
fn reset() []const u8 {
    return if (use_color) "\x1b[0m" else "";
}

// ── Logging ──────────────────────────────────────────────────────────────────

fn logMsg(comptime fmt: []const u8, args: anytype) void {
    stderrPrint("{s}{s}==>{s} " ++ fmt ++ "\n", .{ cyan(), bold(), reset() } ++ args);
}

fn logInfo(comptime fmt: []const u8, args: anytype) void {
    stderrPrint("    {s}" ++ fmt ++ "{s}\n", .{dim()} ++ args ++ .{reset()});
}

fn logErr(comptime fmt: []const u8, args: anytype) void {
    stderrPrint("{s}{s}Error:{s} " ++ fmt ++ "\n", .{ red(), bold(), reset() } ++ args);
}

fn logOk(comptime fmt: []const u8, args: anytype) void {
    stderrPrint("{s}{s}==>{s} " ++ fmt ++ "\n", .{ green(), bold(), reset() } ++ args);
}

fn logWarn(comptime fmt: []const u8, args: anytype) void {
    stderrPrint("{s}{s}==>{s} " ++ fmt ++ "\n", .{ yellow(), bold(), reset() } ++ args);
}

// ── Duration formatting ──────────────────────────────────────────────────────

fn fmtDuration(buf: []u8, seconds: u64) []const u8 {
    if (seconds >= 3600) {
        return std.fmt.bufPrint(buf, "{d}h{d:0>2}m{d:0>2}s", .{ seconds / 3600, (seconds % 3600) / 60, seconds % 60 }) catch "?";
    }
    if (seconds >= 60) {
        return std.fmt.bufPrint(buf, "{d}m{d:0>2}s", .{ seconds / 60, seconds % 60 }) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d}s", .{seconds}) catch "?";
}

// ── CLI args ─────────────────────────────────────────────────────────────────

const CliArgs = struct {
    system: ?[]const u8 = null,
    system_explicit: bool = false,
    name: ?[]const u8 = null,
    cmd: []const []const u8 = &.{},
    sha_pin: ?[]const u8 = null,
    config_file: ?[]const u8 = null,
    tui: bool = false,
    workdir: ?[]const u8 = null,
};

fn printUsage() void {
    stderrWrite(
        \\Usage: giton [options] -- <command...>
        \\       giton -f <config.json>
        \\
        \\Run commands on Nix platforms and post GitHub commit statuses.
        \\
        \\Single-step mode:
        \\  -s, --system    Nix system string (if omitted, runs on current system)
        \\  -n, --name      Check name for GitHub status context (default: command name)
        \\  --              Separator before the command to run
        \\
        \\Multi-step mode:
        \\  -f, --file      JSON config file defining steps, systems, and dependencies
        \\
        \\Common options:
        \\  --sha           Pin to a specific commit SHA (skips clean-tree check)
        \\  --tui           Enable process-compose TUI (multi-step mode only)
        \\
        \\Status context: giton/<name> (no --system) or giton/<name>/<system> (with --system)
        \\
    );
}

fn parseArgs(allocator: mem.Allocator) !CliArgs {
    var args_iter = try process.argsWithAllocator(allocator);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip program name

    var result = CliArgs{};
    var cmd_list: std.ArrayList([]const u8) = .empty;

    var collecting_cmd = false;

    while (args_iter.next()) |arg_raw| {
        const arg = try allocator.dupe(u8, arg_raw);
        if (collecting_cmd) {
            try cmd_list.append(allocator, arg);
            continue;
        }

        if (mem.eql(u8, arg, "--")) {
            collecting_cmd = true;
        } else if (mem.eql(u8, arg, "-s") or mem.eql(u8, arg, "--system")) {
            if (args_iter.next()) |val| {
                result.system = try allocator.dupe(u8, val);
                result.system_explicit = true;
            }
        } else if (mem.eql(u8, arg, "-n") or mem.eql(u8, arg, "--name")) {
            if (args_iter.next()) |val| {
                result.name = try allocator.dupe(u8, val);
            }
        } else if (mem.eql(u8, arg, "--sha")) {
            if (args_iter.next()) |val| {
                result.sha_pin = try allocator.dupe(u8, val);
            }
        } else if (mem.eql(u8, arg, "-f") or mem.eql(u8, arg, "--file")) {
            if (args_iter.next()) |val| {
                result.config_file = try allocator.dupe(u8, val);
            }
        } else if (mem.eql(u8, arg, "--tui")) {
            result.tui = true;
        } else if (mem.eql(u8, arg, "--workdir")) {
            if (args_iter.next()) |val| {
                result.workdir = try allocator.dupe(u8, val);
            }
        } else if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            printUsage();
            process.exit(1);
        } else {
            logErr("Unknown option '{s}'", .{arg});
            printUsage();
            process.exit(1);
        }
    }

    result.cmd = try cmd_list.toOwnedSlice(allocator);
    return result;
}

// ── Command execution ────────────────────────────────────────────────────────

fn runCapture(allocator: mem.Allocator, argv: []const []const u8) !struct { stdout: []const u8, success: bool } {
    const result = try process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
    });
    const success = result.term == .Exited and result.term.Exited == 0;
    allocator.free(result.stderr);
    return .{ .stdout = result.stdout, .success = success };
}

fn runSilent(allocator: mem.Allocator, argv: []const []const u8) u8 {
    const result = process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
    }) catch return 1;
    allocator.free(result.stderr);
    allocator.free(result.stdout);
    return switch (result.term) {
        .Exited => |code| code,
        else => 1,
    };
}

/// Run a command with inherited stdio; return exit code.
fn runInherited(allocator: mem.Allocator, argv: []const []const u8) u8 {
    var child = process.Child.init(argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.spawn() catch return 1;
    const term = child.wait() catch return 1;
    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

// ── Git operations ───────────────────────────────────────────────────────────

fn isInGitRepo(allocator: mem.Allocator) bool {
    const result = runCapture(allocator, &.{ "git", "rev-parse", "--is-inside-work-tree" }) catch return false;
    allocator.free(result.stdout);
    return result.success;
}

fn isTreeClean(allocator: mem.Allocator) bool {
    const result = runCapture(allocator, &.{ "git", "status", "--porcelain" }) catch return false;
    defer allocator.free(result.stdout);
    return mem.trim(u8, result.stdout, &std.ascii.whitespace).len == 0;
}

fn resolveHEAD(allocator: mem.Allocator) ![]const u8 {
    const result = try runCapture(allocator, &.{ "git", "rev-parse", "HEAD" });
    if (!result.success) {
        allocator.free(result.stdout);
        return error.GitFailed;
    }
    const trimmed = mem.trim(u8, result.stdout, &std.ascii.whitespace);
    const owned = try allocator.dupe(u8, trimmed);
    allocator.free(result.stdout);
    return owned;
}

fn shortSHA(sha: []const u8) []const u8 {
    return if (sha.len > 12) sha[0..12] else sha;
}

// ── GitHub operations ────────────────────────────────────────────────────────

fn getRepo(allocator: mem.Allocator) ![]const u8 {
    const result = try runCapture(allocator, &.{ "gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner" });
    if (!result.success) {
        allocator.free(result.stdout);
        return error.GhFailed;
    }
    const trimmed = mem.trim(u8, result.stdout, &std.ascii.whitespace);
    const owned = try allocator.dupe(u8, trimmed);
    allocator.free(result.stdout);
    return owned;
}

fn postStatus(allocator: mem.Allocator, repo: []const u8, sha: []const u8, state: []const u8, context: []const u8, description_raw: []const u8) void {
    const description = if (description_raw.len > 140) description_raw[0..140] else description_raw;

    const api_path = std.fmt.allocPrint(allocator, "repos/{s}/statuses/{s}", .{ repo, sha }) catch return;
    defer allocator.free(api_path);
    const state_arg = std.fmt.allocPrint(allocator, "state={s}", .{state}) catch return;
    defer allocator.free(state_arg);
    const context_arg = std.fmt.allocPrint(allocator, "context={s}", .{context}) catch return;
    defer allocator.free(context_arg);
    const desc_arg = std.fmt.allocPrint(allocator, "description={s}", .{description}) catch return;
    defer allocator.free(desc_arg);

    _ = runSilent(allocator, &.{ "gh", "api", api_path, "-f", state_arg, "-f", context_arg, "-f", desc_arg, "--silent" });
}

// ── Current system ───────────────────────────────────────────────────────────

fn getCurrentSystem(allocator: mem.Allocator) ![]const u8 {
    const result = try runCapture(allocator, &.{ "nix", "eval", "--raw", "--impure", "--expr", "builtins.currentSystem" });
    if (!result.success) {
        allocator.free(result.stdout);
        return error.NixFailed;
    }
    const trimmed = mem.trim(u8, result.stdout, &std.ascii.whitespace);
    const owned = try allocator.dupe(u8, trimmed);
    allocator.free(result.stdout);
    return owned;
}

// ── Host configuration ───────────────────────────────────────────────────────

fn hostsFilePath(allocator: mem.Allocator) ![]const u8 {
    const xdg = process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch |e| blk: {
        if (e == error.EnvironmentVariableNotFound) {
            const home = try process.getEnvVarOwned(allocator, "HOME");
            defer allocator.free(home);
            break :blk try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
        }
        return e;
    };
    defer allocator.free(xdg);
    return std.fmt.allocPrint(allocator, "{s}/giton/hosts.json", .{xdg});
}

fn getRemoteHost(allocator: mem.Allocator, system: []const u8) ![]const u8 {
    // Try loading from saved hosts
    const path = try hostsFilePath(allocator);
    defer allocator.free(path);

    const data = fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch null;
    if (data) |d| {
        defer allocator.free(d);
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, d, .{ .allocate = .alloc_always }) catch null;
        if (parsed) |p| {
            if (p.value == .object) {
                if (p.value.object.get(system)) |val| {
                    if (val == .string and val.string.len > 0) {
                        const host = try allocator.dupe(u8, val.string);
                        logMsg("Using saved host for {s}: {s}{s}{s}", .{ system, bold(), host, reset() });
                        return host;
                    }
                }
            }
        }
    }

    // Prompt for hostname
    stderrPrint("==> Enter hostname for {s}: ", .{system});

    var line_buf: [256]u8 = undefined;
    var total: usize = 0;
    while (total < line_buf.len) {
        const n = posix.read(posix.STDIN_FILENO, line_buf[total..]) catch return error.NoHostname;
        if (n == 0) break;
        // Check if we got a newline
        if (mem.indexOfScalar(u8, line_buf[total .. total + n], '\n')) |nl| {
            total += nl;
            break;
        }
        total += n;
    }
    const line = line_buf[0..total];

    // Validate hostname
    for (line) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '_' and ch != '-') {
            logErr("Invalid hostname: {s}", .{line});
            return error.InvalidHostname;
        }
    }
    if (line.len == 0) {
        logErr("No hostname provided.", .{});
        return error.NoHostname;
    }

    const host = try allocator.dupe(u8, line);
    saveHost(allocator, system, host) catch {
        logWarn("Could not save host", .{});
    };
    return host;
}

fn saveHost(allocator: mem.Allocator, system: []const u8, host: []const u8) !void {
    const path = try hostsFilePath(allocator);
    defer allocator.free(path);

    // Read existing hosts as JSON Value
    var hosts = std.StringArrayHashMap([]const u8).init(allocator);
    const existing = fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch null;
    if (existing) |d| {
        defer allocator.free(d);
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, d, .{ .allocate = .alloc_always }) catch null;
        if (parsed) |p| {
            if (p.value == .object) {
                var it = p.value.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* == .string) {
                        try hosts.put(try allocator.dupe(u8, entry.key_ptr.*), try allocator.dupe(u8, entry.value_ptr.string));
                    }
                }
            }
        }
    }

    try hosts.put(try allocator.dupe(u8, system), try allocator.dupe(u8, host));

    // Write JSON
    const dir_path = fs.path.dirname(path) orelse return error.InvalidPath;
    fs.cwd().makePath(dir_path) catch {};

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\n");
    var first = true;
    var it = hosts.iterator();
    while (it.next()) |entry| {
        if (!first) try buf.appendSlice(allocator, ",\n");
        try buf.print(allocator, "  \"{s}\": \"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
        first = false;
    }
    try buf.appendSlice(allocator, "\n}\n");

    const file = try fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(buf.items);
}

// ── SSH helpers ──────────────────────────────────────────────────────────────

fn ensureSSHControlDir(allocator: mem.Allocator, host: []const u8) void {
    const result = runCapture(allocator, &.{ "ssh", "-G", host }) catch return;
    defer allocator.free(result.stdout);

    var lines = mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (mem.startsWith(u8, line, "controlpath ")) {
            const ctl_path = line["controlpath ".len..];
            if (fs.path.dirname(ctl_path)) |dir| {
                fs.cwd().makePath(dir) catch {};
            }
            break;
        }
    }
}

// ── Repo extraction ──────────────────────────────────────────────────────────

fn extractRepoLocal(allocator: mem.Allocator, sha: []const u8, dir: []const u8) !void {
    fs.cwd().makePath(dir) catch {};
    const cmd = try std.fmt.allocPrint(allocator, "git archive --format=tar {s} | tar -C '{s}' -x && chmod -R u+w '{s}'", .{ sha, dir, dir });
    defer allocator.free(cmd);
    const rc = runInherited(allocator, &.{ "bash", "-c", cmd });
    if (rc != 0) return error.ExtractionFailed;
}

fn extractRepoRemote(allocator: mem.Allocator, sha: []const u8, host: []const u8, dir: []const u8) !void {
    const cmd = try std.fmt.allocPrint(allocator, "git archive --format=tar {s} | ssh {s} \"mkdir -p '{s}' && tar -C '{s}' -x && chmod -R u+w '{s}'\"", .{ sha, host, dir, dir, dir });
    defer allocator.free(cmd);
    const rc = runInherited(allocator, &.{ "bash", "-c", cmd });
    if (rc != 0) return error.RemoteExtractionFailed;
}

// ── Hostname ─────────────────────────────────────────────────────────────────

fn getHostname(allocator: mem.Allocator) []const u8 {
    const result = runCapture(allocator, &.{"hostname"}) catch return "local";
    const trimmed = mem.trim(u8, result.stdout, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        allocator.free(result.stdout);
        return "local";
    }
    const owned = allocator.dupe(u8, trimmed) catch return "local";
    allocator.free(result.stdout);
    return owned;
}

// ── Self path ────────────────────────────────────────────────────────────────

fn selfPathResolved(allocator: mem.Allocator) ![]const u8 {
    var buf: [fs.max_path_bytes]u8 = undefined;
    const link = fs.readLinkAbsolute("/proc/self/exe", &buf) catch {
        // Fallback to argv[0]
        var args = try process.argsWithAllocator(allocator);
        defer args.deinit();
        const arg0 = args.next() orelse return error.NoSelfPath;
        return try allocator.dupe(u8, arg0);
    };
    return try allocator.dupe(u8, link);
}

// ── Log name sanitization ────────────────────────────────────────────────────

fn sanitizeLogName(allocator: mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var prev_dash = false;
    for (name) |ch| {
        if (ch == '/' or ch == ' ' or ch == '(' or ch == ')') {
            if (!prev_dash) {
                try buf.append(allocator, '-');
                prev_dash = true;
            }
        } else {
            try buf.append(allocator, ch);
            prev_dash = false;
        }
    }
    var result = try buf.toOwnedSlice(allocator);
    while (result.len > 0 and result[result.len - 1] == '-') {
        result = result[0 .. result.len - 1];
    }
    return result;
}

// ── JSON config parsing ──────────────────────────────────────────────────────

const StepConfig = struct {
    command: []const u8,
    systems: ?[]const []const u8 = null,
    depends_on: ?[]const []const u8 = null,
};

fn parseConfig(allocator: mem.Allocator, data: []const u8) !std.StringArrayHashMap(StepConfig) {
    var result = std.StringArrayHashMap(StepConfig).init(allocator);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{ .allocate = .alloc_always });
    const root_val = parsed.value;
    if (root_val != .object) return error.InvalidConfig;

    const steps_val = root_val.object.get("steps") orelse return error.InvalidConfig;
    if (steps_val != .object) return error.InvalidConfig;

    var steps_it = steps_val.object.iterator();
    while (steps_it.next()) |entry| {
        const step_name = try allocator.dupe(u8, entry.key_ptr.*);
        const step_obj = entry.value_ptr.*;
        if (step_obj != .object) continue;

        var step = StepConfig{ .command = "" };

        if (step_obj.object.get("command")) |cmd_val| {
            if (cmd_val == .string) {
                step.command = try allocator.dupe(u8, cmd_val.string);
            }
        }

        if (step_obj.object.get("systems")) |sys_val| {
            if (sys_val == .array) {
                var systems: std.ArrayList([]const u8) = .empty;
                for (sys_val.array.items) |item| {
                    if (item == .string) {
                        try systems.append(allocator, try allocator.dupe(u8, item.string));
                    }
                }
                step.systems = try systems.toOwnedSlice(allocator);
            }
        }

        if (step_obj.object.get("depends_on")) |deps_val| {
            if (deps_val == .array) {
                var deps: std.ArrayList([]const u8) = .empty;
                for (deps_val.array.items) |item| {
                    if (item == .string) {
                        try deps.append(allocator, try allocator.dupe(u8, item.string));
                    }
                }
                step.depends_on = try deps.toOwnedSlice(allocator);
            }
        }

        try result.put(step_name, step);
    }

    return result;
}

// ── Process entry for multi-step ─────────────────────────────────────────────

const ProcessEntry = struct {
    step: []const u8,
    sys: ?[]const u8,
    key: []const u8,
};

fn buildProcessEntries(allocator: mem.Allocator, config: std.StringArrayHashMap(StepConfig)) ![]ProcessEntry {
    var procs: std.ArrayList(ProcessEntry) = .empty;

    var it = config.iterator();
    while (it.next()) |entry| {
        const step_name = entry.key_ptr.*;
        const step = entry.value_ptr.*;
        const systems = step.systems;

        if (systems == null or systems.?.len == 0) {
            try procs.append(allocator, .{
                .step = step_name,
                .sys = null,
                .key = step_name,
            });
        } else {
            for (systems.?) |sys| {
                const key = if (systems.?.len > 1)
                    try std.fmt.allocPrint(allocator, "{s} ({s})", .{ step_name, sys })
                else
                    step_name;
                try procs.append(allocator, .{
                    .step = step_name,
                    .sys = sys,
                    .key = key,
                });
            }
        }
    }

    return try procs.toOwnedSlice(allocator);
}

// ── JSON string escaping ─────────────────────────────────────────────────────

fn writeJsonString(list: *std.ArrayList(u8), allocator: mem.Allocator, s: []const u8) !void {
    try list.append(allocator, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => try list.append(allocator, ch),
        }
    }
    try list.append(allocator, '"');
}

// ── Generate process-compose JSON ────────────────────────────────────────────

fn generatePCConfig(
    allocator: mem.Allocator,
    procs: []const ProcessEntry,
    config: std.StringArrayHashMap(StepConfig),
    sha: []const u8,
    self_bin: []const u8,
    cwd: []const u8,
    log_dir: []const u8,
    host_map: std.StringArrayHashMap([]const u8),
    workdir_map: std.StringArrayHashMap([]const u8),
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    try buf.appendSlice(allocator, "{\n  \"version\": \"0.5\",\n  \"log_configuration\": {\"flush_each_line\": true},\n  \"processes\": {\n");

    for (procs, 0..) |p, pi| {
        if (pi > 0) try buf.appendSlice(allocator, ",\n");

        const step = config.get(p.step).?;

        // Build command string
        var cmd_buf: std.ArrayList(u8) = .empty;
        defer cmd_buf.deinit(allocator);
        try cmd_buf.print(allocator, "{s} --sha {s}", .{ self_bin, sha });
        if (p.sys) |sys| {
            try cmd_buf.print(allocator, " -s {s}", .{sys});
            if (workdir_map.get(sys)) |wdir| {
                try cmd_buf.print(allocator, " --workdir {s}", .{wdir});
            }
        }
        try cmd_buf.print(allocator, " -n {s} -- {s}", .{ p.step, step.command });

        // Log file
        const sanitized = try sanitizeLogName(allocator, p.key);
        defer allocator.free(sanitized);
        const log_file = try std.fmt.allocPrint(allocator, "{s}/{s}.log", .{ log_dir, sanitized });
        defer allocator.free(log_file);

        // Write process entry
        try buf.appendSlice(allocator, "    ");
        try writeJsonString(&buf, allocator, p.key);
        try buf.appendSlice(allocator, ": {\n      \"command\": ");
        try writeJsonString(&buf, allocator, cmd_buf.items);
        try buf.appendSlice(allocator, ",\n      \"working_dir\": ");
        try writeJsonString(&buf, allocator, cwd);
        try buf.appendSlice(allocator, ",\n      \"log_location\": ");
        try writeJsonString(&buf, allocator, log_file);

        // Namespace
        if (p.sys) |sys| {
            const hostname = host_map.get(sys) orelse "local";
            const ns = try std.fmt.allocPrint(allocator, "{s} ({s})", .{ sys, hostname });
            defer allocator.free(ns);
            try buf.appendSlice(allocator, ",\n      \"namespace\": ");
            try writeJsonString(&buf, allocator, ns);
        }

        try buf.appendSlice(allocator, ",\n      \"availability\": {\"restart\": \"exit_on_failure\"}");

        // Dependencies
        const deps = step.depends_on;
        if (deps != null and deps.?.len > 0) {
            try buf.appendSlice(allocator, ",\n      \"depends_on\": {");
            var first_dep = true;
            for (deps.?) |dep| {
                for (procs) |dp| {
                    const sys_match = if (p.sys) |ps| (if (dp.sys) |ds| mem.eql(u8, ps, ds) else false) else (dp.sys == null);
                    if (mem.eql(u8, dp.step, dep) and sys_match) {
                        if (!first_dep) try buf.appendSlice(allocator, ",");
                        try buf.appendSlice(allocator, "\n        ");
                        try writeJsonString(&buf, allocator, dp.key);
                        try buf.appendSlice(allocator, ": {\"condition\": \"process_completed_successfully\"}");
                        first_dep = false;
                        break;
                    }
                }
            }
            try buf.appendSlice(allocator, "\n      }");
        }

        try buf.appendSlice(allocator, "\n    }");
    }

    try buf.appendSlice(allocator, "\n  }\n}\n");
    return try buf.toOwnedSlice(allocator);
}

// ── Multi-step mode ──────────────────────────────────────────────────────────

fn runMultiStep(allocator: mem.Allocator, args: CliArgs, sha: []const u8) u8 {
    const config_file = args.config_file.?;

    const data = fs.cwd().readFileAlloc(allocator, config_file, 10 * 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) {
            logErr("Config file not found: {s}", .{config_file});
        } else {
            logErr("Failed to read config: {s}", .{config_file});
        }
        return 1;
    };
    defer allocator.free(data);

    const config = parseConfig(allocator, data) catch {
        logErr("Failed to parse config: invalid JSON", .{});
        return 1;
    };

    logMsg("Multi-step mode: {s}{s}{s}  {s}SHA={s}{s}", .{ bold(), config_file, reset(), dim(), shortSHA(sha), reset() });

    const current_system = getCurrentSystem(allocator) catch {
        logErr("Could not determine current system", .{});
        return 1;
    };

    var cwd_buf: [4096]u8 = undefined;
    const cwd = process.getCwd(&cwd_buf) catch {
        logErr("Could not get working directory", .{});
        return 1;
    };
    const cwd_owned = allocator.dupe(u8, cwd) catch return 1;

    // Collect unique systems
    var all_systems: std.ArrayList([]const u8) = .empty;
    var seen_systems = std.StringArrayHashMap(void).init(allocator);
    var cfg_it = config.iterator();
    while (cfg_it.next()) |entry| {
        const step = entry.value_ptr.*;
        if (step.systems) |systems| {
            for (systems) |sys| {
                if (!seen_systems.contains(sys)) {
                    seen_systems.put(sys, {}) catch {};
                    all_systems.append(allocator, sys) catch {};
                }
            }
        }
    }

    // Build host map
    var host_map = std.StringArrayHashMap([]const u8).init(allocator);
    host_map.put(current_system, getHostname(allocator)) catch return 1;

    for (all_systems.items) |sys| {
        if (!mem.eql(u8, sys, current_system)) {
            const host = getRemoteHost(allocator, sys) catch {
                logErr("Failed to get host for {s}", .{sys});
                return 1;
            };
            host_map.put(sys, host) catch return 1;

            logMsg("Warming SSH connection to {s}{s}{s} ({s})...", .{ bold(), host, reset(), sys });
            _ = runSilent(allocator, &.{ "ssh", host, "echo", "ok" });
        }
    }

    // Pre-extract repo per system
    const workdir_base = std.fmt.allocPrint(allocator, "/tmp/giton-{s}", .{shortSHA(sha)}) catch return 1;
    var workdir_map = std.StringArrayHashMap([]const u8).init(allocator);

    // Local
    const local_dir = std.fmt.allocPrint(allocator, "{s}-local", .{workdir_base}) catch return 1;
    logMsg("Extracting repo (local)...", .{});
    extractRepoLocal(allocator, sha, local_dir) catch {
        logErr("Failed to extract repo locally", .{});
        return 1;
    };
    workdir_map.put(current_system, local_dir) catch return 1;

    // Remote systems
    for (all_systems.items) |sys| {
        if (!mem.eql(u8, sys, current_system)) {
            const host = host_map.get(sys).?;
            const rdir = std.fmt.allocPrint(allocator, "{s}-{s}", .{ workdir_base, sys }) catch return 1;
            logMsg("Extracting repo on {s}{s}{s} ({s})...", .{ bold(), host, reset(), sys });
            extractRepoRemote(allocator, sha, host, rdir) catch {
                logErr("Failed to extract repo on {s}", .{host});
                return 1;
            };
            workdir_map.put(sys, rdir) catch return 1;
        }
    }

    const log_dir = std.fmt.allocPrint(allocator, "/tmp/giton-{s}-logs", .{shortSHA(sha)}) catch return 1;
    fs.cwd().makePath(log_dir) catch {};

    // Build process entries
    const procs = buildProcessEntries(allocator, config) catch return 1;

    // Resolve self path
    const self_bin = selfPathResolved(allocator) catch {
        logErr("Could not resolve self path", .{});
        return 1;
    };

    // Generate process-compose config
    const pc_config = generatePCConfig(allocator, procs, config, sha, self_bin, cwd_owned, log_dir, host_map, workdir_map) catch return 1;

    // Write to temp file
    const pc_file_path = std.fmt.allocPrint(allocator, "/tmp/giton-pc-{s}.json", .{shortSHA(sha)}) catch return 1;

    {
        const file = fs.cwd().createFile(pc_file_path, .{}) catch return 1;
        defer file.close();
        file.writeAll(pc_config) catch return 1;
    }

    // Run process-compose
    const tui_arg: []const u8 = if (args.tui) "--tui=true" else "--tui=false";
    const pc_exit = runInherited(allocator, &.{ "process-compose", "up", tui_arg, "--no-server", "--config", pc_file_path });

    // Cleanup
    fs.cwd().deleteFile(pc_file_path) catch {};
    fs.cwd().deleteTree(local_dir) catch {};
    for (all_systems.items) |sys| {
        if (!mem.eql(u8, sys, current_system)) {
            const host = host_map.get(sys) orelse continue;
            const rdir = std.fmt.allocPrint(allocator, "{s}-{s}", .{ workdir_base, sys }) catch continue;
            const rm_cmd = std.fmt.allocPrint(allocator, "rm -rf '{s}'", .{rdir}) catch continue;
            _ = runSilent(allocator, &.{ "ssh", host, rm_cmd });
        }
    }

    // Summary
    stderrWrite("\n");
    if (pc_exit == 0) {
        logOk("All steps passed", .{});
    } else {
        logWarn("One or more steps failed (exit {d})", .{pc_exit});
        logInfo("Logs: {s}/", .{log_dir});
        if (!args.tui) {
            printFailedLogs(allocator, log_dir);
        }
    }

    return pc_exit;
}

fn printFailedLogs(allocator: mem.Allocator, log_dir: []const u8) void {
    var dir = fs.cwd().openDir(log_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (!mem.endsWith(u8, entry.name, ".log")) continue;

        const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ log_dir, entry.name }) catch continue;
        defer allocator.free(full_path);

        const content = fs.cwd().readFileAlloc(allocator, full_path, 10 * 1024 * 1024) catch continue;
        defer allocator.free(content);

        if (content.len == 0) continue;
        if (mem.indexOf(u8, content, "failed") == null) continue;

        const step_name = entry.name[0 .. entry.name.len - 4];
        stderrWrite("\n");
        logWarn("{s}{s}{s}:", .{ bold(), step_name, reset() });

        var lines = mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{ .allocate = .alloc_always }) catch {
                stderrPrint("{s}\n", .{line});
                continue;
            };
            if (parsed.value == .object) {
                if (parsed.value.object.get("message")) |msg_val| {
                    if (msg_val == .string) {
                        stderrPrint("{s}\n", .{msg_val.string});
                    }
                }
            }
        }
    }
}

// ── Single-step mode ─────────────────────────────────────────────────────────

fn runSingleStep(allocator: mem.Allocator, args: CliArgs, sha: []const u8) u8 {
    const name = args.name orelse blk: {
        const cmd0 = args.cmd[0];
        const idx = mem.lastIndexOfScalar(u8, cmd0, '/');
        break :blk if (idx) |i| cmd0[i + 1 ..] else cmd0;
    };

    var context_buf: [512]u8 = undefined;
    const context = if (args.system_explicit)
        std.fmt.bufPrint(&context_buf, "giton/{s}/{s}", .{ name, args.system.? }) catch "giton/?"
    else
        std.fmt.bufPrint(&context_buf, "giton/{s}", .{name}) catch "giton/?";

    const repo = getRepo(allocator) catch {
        logErr("Could not determine GitHub repository. Is 'gh' authenticated?", .{});
        return 1;
    };

    // Build command string
    var cmd_str_buf: std.ArrayList(u8) = .empty;
    defer cmd_str_buf.deinit(allocator);
    for (args.cmd, 0..) |part, i| {
        if (i > 0) cmd_str_buf.appendSlice(allocator, " ") catch {};
        cmd_str_buf.appendSlice(allocator, part) catch {};
    }
    const cmd_str = cmd_str_buf.items;

    logMsg("{s}{s}{s}  {s}{s}@{s}{s}", .{ bold(), context, reset(), dim(), repo, shortSHA(sha), reset() });
    logInfo("{s}", .{cmd_str});

    const pending_desc = std.fmt.allocPrint(allocator, "Running: {s}", .{cmd_str}) catch "Running";
    postStatus(allocator, repo, sha, "pending", context, pending_desc);

    const remote = args.system_explicit and !mem.eql(u8, getCurrentSystem(allocator) catch "", args.system.?);

    const timer = std.time.Timer.start() catch null;
    var rc: u8 = 0;

    if (args.workdir) |workdir| {
        if (remote) {
            const host = getRemoteHost(allocator, args.system.?) catch {
                logErr("Failed to get remote host", .{});
                return 1;
            };
            rc = runSSHCmd(allocator, host, workdir, args.cmd);
        } else {
            rc = runLocalCmd(allocator, workdir, args.cmd);
        }
    } else if (remote) {
        const host = getRemoteHost(allocator, args.system.?) catch {
            logErr("Failed to get remote host", .{});
            return 1;
        };
        const remote_dir = std.fmt.allocPrint(allocator, "/tmp/giton-{s}", .{shortSHA(sha)}) catch return 1;

        ensureSSHControlDir(allocator, host);
        logMsg("Copying repo to {s}{s}{s}...", .{ bold(), host, reset() });
        extractRepoRemote(allocator, sha, host, remote_dir) catch {
            logErr("Failed to extract repo remotely", .{});
            return 1;
        };
        rc = runSSHCmd(allocator, host, remote_dir, args.cmd);

        // Cleanup
        logMsg("Cleaning up remote temp dir...", .{});
        const rm_cmd = std.fmt.allocPrint(allocator, "rm -rf '{s}'", .{remote_dir}) catch "";
        _ = runSilent(allocator, &.{ "ssh", host, rm_cmd });
    } else {
        // Local: mktemp
        const mktemp_tpl = std.fmt.allocPrint(allocator, "/tmp/giton-{s}-XXXXXX", .{shortSHA(sha)}) catch return 1;
        const result = runCapture(allocator, &.{ "mktemp", "-d", mktemp_tpl }) catch return 1;
        defer allocator.free(result.stdout);
        const tmpdir = allocator.dupe(u8, mem.trim(u8, result.stdout, &std.ascii.whitespace)) catch return 1;

        logMsg("Extracting repo...", .{});
        extractRepoLocal(allocator, sha, tmpdir) catch {
            logErr("Failed to extract repo", .{});
            return 1;
        };
        rc = runLocalCmd(allocator, tmpdir, args.cmd);

        // Cleanup
        fs.cwd().deleteTree(tmpdir) catch {};
    }

    var elapsed_buf: [32]u8 = undefined;
    var timer_mut = timer;
    const elapsed = if (timer_mut) |*t| blk: {
        const ns = t.read();
        const secs = ns / std.time.ns_per_s;
        break :blk fmtDuration(&elapsed_buf, secs);
    } else "0s";

    if (rc == 0) {
        logOk("{s}{s}{s} passed in {s}{s}{s}", .{ bold(), context, reset(), green(), elapsed, reset() });
        const desc = std.fmt.allocPrint(allocator, "Passed in {s}: {s}", .{ elapsed, cmd_str }) catch "Passed";
        postStatus(allocator, repo, sha, "success", context, desc);
    } else {
        logWarn("{s}{s}{s} failed (exit {d}) in {s}{s}{s}", .{ bold(), context, reset(), rc, yellow(), elapsed, reset() });
        const desc = std.fmt.allocPrint(allocator, "Failed (exit {d}) in {s}: {s}", .{ rc, elapsed, cmd_str }) catch "Failed";
        postStatus(allocator, repo, sha, "failure", context, desc);
    }

    return rc;
}

fn runLocalCmd(allocator: mem.Allocator, dir: []const u8, cmd_args: []const []const u8) u8 {
    var cmd_str: std.ArrayList(u8) = .empty;
    defer cmd_str.deinit(allocator);
    for (cmd_args) |part| {
        cmd_str.appendSlice(allocator, part) catch {};
        cmd_str.append(allocator, ' ') catch {};
    }

    const shell_cmd = std.fmt.allocPrint(allocator, "cd '{s}' && {s}", .{ dir, cmd_str.items }) catch return 1;
    defer allocator.free(shell_cmd);
    return runInherited(allocator, &.{ "bash", "-c", shell_cmd });
}

fn runSSHCmd(allocator: mem.Allocator, host: []const u8, dir: []const u8, cmd_args: []const []const u8) u8 {
    var cmd_str: std.ArrayList(u8) = .empty;
    defer cmd_str.deinit(allocator);
    for (cmd_args) |part| {
        cmd_str.appendSlice(allocator, part) catch {};
        cmd_str.append(allocator, ' ') catch {};
    }

    const remote_cmd = std.fmt.allocPrint(allocator, "cd '{s}' && {s}", .{ dir, cmd_str.items }) catch return 1;
    defer allocator.free(remote_cmd);
    return runInherited(allocator, &.{ "ssh", host, remote_cmd });
}

// ── Main ─────────────────────────────────────────────────────────────────────

pub fn main() void {
    initColor();
    const allocator = std.heap.page_allocator;
    const args = parseArgs(allocator) catch {
        logErr("Failed to parse arguments", .{});
        process.exit(1);
    };

    if (!isInGitRepo(allocator)) {
        logErr("Not inside a git repository.", .{});
        process.exit(1);
    }

    var sha: []const u8 = undefined;
    if (args.sha_pin) |pin| {
        sha = pin;
    } else {
        if (!isTreeClean(allocator)) {
            logErr("Working tree is dirty. Commit or stash changes first.", .{});
            process.exit(1);
        }
        sha = resolveHEAD(allocator) catch {
            logErr("Could not resolve HEAD", .{});
            process.exit(1);
        };
    }

    if (args.config_file != null) {
        process.exit(runMultiStep(allocator, args, sha));
    }

    if (args.cmd.len == 0) {
        logErr("A command after -- is required (or use -f for multi-step mode).", .{});
        printUsage();
        process.exit(1);
    }

    process.exit(runSingleStep(allocator, args, sha));
}
