const std = @import("std");

pub const Id = ?*anyopaque;
pub const Class = ?*anyopaque;
pub const Sel = ?*anyopaque;
pub const Ivar = ?*anyopaque;
pub const MethodImplementation = *const fn () callconv(.c) void;

extern "c" fn objc_getClass(name: [*:0]const u8) Class;
extern "c" fn objc_lookUpClass(name: [*:0]const u8) Class;
extern "c" fn sel_registerName(name: [*:0]const u8) Sel;
extern "c" fn objc_msgSend() callconv(.c) void;
extern "c" fn objc_retain(value: Id) Id;
extern "c" fn objc_release(value: Id) void;
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;
extern "c" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra_bytes: usize) Class;
extern "c" fn objc_registerClassPair(cls: Class) void;
extern "c" fn class_addMethod(cls: Class, name: Sel, implementation: MethodImplementation, types: [*:0]const u8) bool;
extern "c" fn class_addIvar(cls: Class, name: [*:0]const u8, size: usize, alignment: u8, types: [*:0]const u8) bool;
extern "c" fn object_setInstanceVariable(object: Id, name: [*:0]const u8, value: ?*anyopaque) Ivar;
extern "c" fn object_getInstanceVariable(object: Id, name: [*:0]const u8, value: *?*anyopaque) Ivar;
extern "c" fn object_getClass(object: Id) Class;

pub inline fn class(name: [*:0]const u8) Class {
    return objc_getClass(name);
}

pub inline fn lookupClass(name: [*:0]const u8) Class {
    return objc_lookUpClass(name);
}

pub inline fn selector(name: [*:0]const u8) Sel {
    return sel_registerName(name);
}

pub inline fn retain(value: Id) Id {
    return if (value != null) objc_retain(value) else null;
}

pub inline fn release(value: Id) void {
    if (value != null) objc_release(value);
}

pub const AutoreleasePool = struct {
    token: ?*anyopaque,

    pub inline fn init() AutoreleasePool {
        return .{ .token = objc_autoreleasePoolPush() };
    }

    pub inline fn deinit(self: AutoreleasePool) void {
        objc_autoreleasePoolPop(self.token);
    }
};

fn function(comptime Function: type) *const Function {
    return @ptrCast(&objc_msgSend);
}

pub inline fn send0(comptime Result: type, receiver: Id, operation: Sel) Result {
    const Function = fn (Id, Sel) callconv(.c) Result;
    return function(Function)(receiver, operation);
}

pub inline fn send1(comptime Result: type, comptime A0: type, receiver: Id, operation: Sel, a0: A0) Result {
    const Function = fn (Id, Sel, A0) callconv(.c) Result;
    return function(Function)(receiver, operation, a0);
}

pub inline fn send2(comptime Result: type, comptime A0: type, comptime A1: type, receiver: Id, operation: Sel, a0: A0, a1: A1) Result {
    const Function = fn (Id, Sel, A0, A1) callconv(.c) Result;
    return function(Function)(receiver, operation, a0, a1);
}

pub inline fn send3(comptime Result: type, comptime A0: type, comptime A1: type, comptime A2: type, receiver: Id, operation: Sel, a0: A0, a1: A1, a2: A2) Result {
    const Function = fn (Id, Sel, A0, A1, A2) callconv(.c) Result;
    return function(Function)(receiver, operation, a0, a1, a2);
}

pub inline fn send4(comptime Result: type, comptime A0: type, comptime A1: type, comptime A2: type, comptime A3: type, receiver: Id, operation: Sel, a0: A0, a1: A1, a2: A2, a3: A3) Result {
    const Function = fn (Id, Sel, A0, A1, A2, A3) callconv(.c) Result;
    return function(Function)(receiver, operation, a0, a1, a2, a3);
}

pub inline fn send5(comptime Result: type, comptime A0: type, comptime A1: type, comptime A2: type, comptime A3: type, comptime A4: type, receiver: Id, operation: Sel, a0: A0, a1: A1, a2: A2, a3: A3, a4: A4) Result {
    const Function = fn (Id, Sel, A0, A1, A2, A3, A4) callconv(.c) Result;
    return function(Function)(receiver, operation, a0, a1, a2, a3, a4);
}

pub inline fn allocateClassPair(superclass: Class, name: [*:0]const u8) Class {
    return objc_allocateClassPair(superclass, name, 0);
}

pub inline fn registerClassPair(cls: Class) void {
    objc_registerClassPair(cls);
}

pub inline fn addMethod(cls: Class, name: Sel, implementation: anytype, types: [*:0]const u8) bool {
    return class_addMethod(cls, name, @ptrCast(implementation), types);
}

pub inline fn addPointerIvar(cls: Class, name: [*:0]const u8) bool {
    return class_addIvar(cls, name, @sizeOf(?*anyopaque), @ctz(@as(usize, @alignOf(?*anyopaque))), "^v");
}

pub inline fn setPointerIvar(object: Id, name: [*:0]const u8, value: ?*anyopaque) void {
    _ = object_setInstanceVariable(object, name, value);
}

pub inline fn getPointerIvar(comptime T: type, object: Id, name: [*:0]const u8) ?*T {
    var value: ?*anyopaque = null;
    _ = object_getInstanceVariable(object, name, &value);
    return if (value) |pointer| @ptrCast(@alignCast(pointer)) else null;
}

pub inline fn metaclass(object: Id) Class {
    return object_getClass(object);
}

pub fn nsString(bytes: []const u8) Id {
    const allocated = send0(Id, class("NSString"), selector("alloc"));
    return send3(Id, [*]const u8, usize, usize, allocated, selector("initWithBytes:length:encoding:"), bytes.ptr, bytes.len, 4);
}

pub fn copyUtf8Into(value: Id, output: []u8) []const u8 {
    if (value == null or output.len == 0) return output[0..0];
    const length = send1(usize, usize, value, selector("lengthOfBytesUsingEncoding:"), 4);
    const pointer = send0(?[*:0]const u8, value, selector("UTF8String")) orelse return output[0..0];
    const copied = @min(length, output.len);
    @memcpy(output[0..copied], pointer[0..copied]);
    return output[0..copied];
}

pub fn copyUtf8Alloc(allocator: std.mem.Allocator, value: Id) ![]u8 {
    if (value == null) return allocator.alloc(u8, 0);
    const length = send1(usize, usize, value, selector("lengthOfBytesUsingEncoding:"), 4);
    const output = try allocator.alloc(u8, length);
    errdefer allocator.free(output);
    const pointer = send0(?[*:0]const u8, value, selector("UTF8String")) orelse return error.InvalidUtf8String;
    @memcpy(output, pointer[0..length]);
    return output;
}

pub fn isKindOfClass(value: Id, expected: Class) bool {
    return value != null and send1(bool, Class, value, selector("isKindOfClass:"), expected);
}
