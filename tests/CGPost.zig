const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cDefine("CGREMOTEOPERATION_H_", "1");
    @cDefine("_DEV_EVENT_H", "1");
    @cDefine("NX_ALPHASHIFTMASK", "0x00010000");
    @cDefine("NX_SHIFTMASK", "0x00020000");
    @cDefine("NX_CONTROLMASK", "0x00040000");
    @cDefine("NX_ALTERNATEMASK", "0x00080000");
    @cDefine("NX_COMMANDMASK", "0x00100000");
    @cDefine("NX_NUMERICPADMASK", "0x00200000");
    @cDefine("NX_HELPMASK", "0x00400000");
    @cDefine("NX_SECONDARYFNMASK", "0x00800000");
    @cDefine("NX_NONCOALSESCEDMASK", "0x00000100");
    @cDefine("NX_NULLEVENT", "0");
    @cDefine("NX_LMOUSEDOWN", "1");
    @cDefine("NX_LMOUSEUP", "2");
    @cDefine("NX_RMOUSEDOWN", "3");
    @cDefine("NX_RMOUSEUP", "4");
    @cDefine("NX_MOUSEMOVED", "5");
    @cDefine("NX_LMOUSEDRAGGED", "6");
    @cDefine("NX_RMOUSEDRAGGED", "7");
    @cDefine("NX_KEYDOWN", "10");
    @cDefine("NX_KEYUP", "11");
    @cDefine("NX_FLAGSCHANGED", "12");
    @cDefine("NX_SCROLLWHEELMOVED", "22");
    @cDefine("NX_TABLETPOINTER", "23");
    @cDefine("NX_TABLETPROXIMITY", "24");
    @cDefine("NX_OMOUSEDOWN", "25");
    @cDefine("NX_OMOUSEUP", "26");
    @cDefine("NX_OMOUSEDRAGGED", "27");
    @cDefine("CGKeyCode", "uint16_t");
    @cInclude("CoreFoundation/CFData.h");
    @cDefine("CFMachPortRef", "void *");
    @cInclude("CoreGraphics/CGError.h");
    @cInclude("CoreGraphics/CGGeometry.h");
    @cInclude("CoreGraphics/CGEvent.h");
    @cInclude("unistd.h");
});

comptime {
    if (builtin.cpu.arch != .aarch64 or builtin.os.tag != .macos)
        @compileError("CGPost must target arm64 macOS");
}

fn eventFlags(value: []const u8) c.CGEventFlags {
    var result: c.CGEventFlags = 0;
    var components = std.mem.splitScalar(u8, value, ',');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "command")) {
            result |= c.kCGEventFlagMaskCommand;
        } else if (std.mem.eql(u8, component, "shift")) {
            result |= c.kCGEventFlagMaskShift;
        } else if (std.mem.eql(u8, component, "control")) {
            result |= c.kCGEventFlagMaskControl;
        } else if (std.mem.eql(u8, component, "option")) {
            result |= c.kCGEventFlagMaskAlternate;
        }
    }
    return result;
}

fn chord(desired: c.CGEventFlags, down: bool) !void {
    const event = c.CGEventCreateKeyboardEvent(null, 56, down) orelse return error.CouldNotCreateEvent;
    defer c.CFRelease(event);
    c.CGEventSetFlags(event, if (down) desired else 0);
    c.CGEventPost(c.kCGHIDEventTap, event);
}

fn milliseconds(value: []const u8, default: u32) u32 {
    return std.fmt.parseInt(u32, value, 10) catch default;
}

fn run(args: []const []const u8) !void {
    if (args.len < 2) return error.MissingMode;

    std.debug.print("CGEvent post access: {s}\n", .{if (c.CGPreflightPostEventAccess()) "true" else "false"});

    if (std.mem.eql(u8, args[1], "modifier-double")) {
        if (args.len < 5) return error.MissingArgument;
        _ = try std.fmt.parseInt(u16, args[2], 10);
        const flags = eventFlags(args[3]);
        const gap = milliseconds(args[4], 120);
        try chord(flags, true);
        _ = c.usleep(40_000);
        try chord(flags, false);
        _ = c.usleep(gap * 1_000);
        try chord(flags, true);
        _ = c.usleep(40_000);
        try chord(flags, false);
    } else if (std.mem.eql(u8, args[1], "modifier-hold")) {
        if (args.len < 5) return error.MissingArgument;
        _ = try std.fmt.parseInt(u16, args[2], 10);
        const flags = eventFlags(args[3]);
        const duration = milliseconds(args[4], 450);
        try chord(flags, true);
        _ = c.usleep(duration * 1_000);
        try chord(flags, false);
    } else if (std.mem.eql(u8, args[1], "click-appkit")) {
        if (args.len < 4) return error.MissingArgument;
        const point = c.CGPoint{
            .x = try std.fmt.parseFloat(f64, args[2]),
            .y = try std.fmt.parseFloat(f64, args[3]),
        };
        const down = c.CGEventCreateMouseEvent(null, c.kCGEventLeftMouseDown, point, c.kCGMouseButtonLeft) orelse return error.CouldNotCreateEvent;
        defer c.CFRelease(down);
        c.CGEventPost(c.kCGHIDEventTap, down);
        _ = c.usleep(60_000);
        const up = c.CGEventCreateMouseEvent(null, c.kCGEventLeftMouseUp, point, c.kCGMouseButtonLeft) orelse return error.CouldNotCreateEvent;
        defer c.CFRelease(up);
        c.CGEventPost(c.kCGHIDEventTap, up);
    } else {
        return error.UnknownMode;
    }
}

pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch {
        std.debug.print("could not read arguments\n", .{});
        std.process.exit(2);
    };
    run(args) catch |err| {
        std.debug.print("CGPost failed: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
}
