const std = @import("std");
const native_sdk = @import("native_sdk");
const objc = @import("objc.zig");

const Id = objc.Id;
const Sel = objc.Sel;
const CGFloat = f64;
const NSInteger = isize;
const NSUInteger = usize;

extern "c" fn CGWindowLevelForKey(key: i32) i32;

pub const Point = extern struct { x: CGFloat, y: CGFloat };
pub const Size = extern struct { width: CGFloat, height: CGFloat };
pub const ScreenFrame = extern struct {
    origin: Point,
    size: Size,

    pub fn init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) ScreenFrame {
        return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = width, .height = height } };
    }
};
const Rect = ScreenFrame;

pub const EventSink = struct {
    context: *anyopaque,
    emit: *const fn (context: *anyopaque, action: []const u8) void,
};

const panel_width: CGFloat = 264;
const panel_height: CGFloat = 52;
const target_ivar: [*:0]const u8 = "_fridayOverlayState";
const autosave_name = "FridayOverlayPosition";

const style_nonactivating_panel: NSUInteger = 1 << 7;
const backing_buffered: NSUInteger = 2;
const collection_all_spaces: NSUInteger = 1 << 0;
const collection_fullscreen_auxiliary: NSUInteger = 1 << 8;
const autoresize_width: NSUInteger = 1 << 1;
const autoresize_height: NSUInteger = 1 << 4;
const visual_effect_state_active: NSInteger = 1;
const material_window_background: NSInteger = 12;
const material_hud_window: NSInteger = 13;
const bezel_inline: NSUInteger = 15;
const line_break_truncating_tail: NSInteger = 4;
const floating_window_level_key: i32 = 5;
const fade_in_seconds: f64 = 0.14;
const fade_out_seconds: f64 = 0.12;
const meter_animation_seconds: f64 = 0.11;

const Mode = enum { held, locked, transcribing };
const Action = enum { none, stop, dismiss, cancel };

const ProbeSnapshot = struct {
    ok: bool = false,
    source_pid: i32 = 0,
    frontmost_pid: i32 = 0,
    friday_active: bool = false,
    states_complete: bool = false,
    dismiss_contract: bool = false,
    appearance_contract: bool = false,
    reduced_motion_contract: bool = false,
    button_rect: Rect = Rect.init(0, 0, 0, 0),
};
const Mutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Mutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};

const Classes = struct { panel: objc.Class, target: objc.Class };
var class_mutex: Mutex = .{};

fn ensureClasses() !Classes {
    class_mutex.lock();
    defer class_mutex.unlock();

    var panel_class = objc.lookupClass("FridayZigOverlayPanel");
    if (panel_class == null) {
        panel_class = objc.allocateClassPair(objc.class("NSPanel"), "FridayZigOverlayPanel");
        if (panel_class == null) return error.ObjectiveCClassCreationFailed;
        if (!objc.addMethod(panel_class, objc.selector("canBecomeKeyWindow"), &panelCanBecomeKey, "c@:")) return error.ObjectiveCClassCreationFailed;
        if (!objc.addMethod(panel_class, objc.selector("canBecomeMainWindow"), &panelCanBecomeMain, "c@:")) return error.ObjectiveCClassCreationFailed;
        objc.registerClassPair(panel_class);
    }

    var target_class = objc.lookupClass("FridayZigOverlayTarget");
    if (target_class == null) {
        target_class = objc.allocateClassPair(objc.class("NSObject"), "FridayZigOverlayTarget");
        if (target_class == null) return error.ObjectiveCClassCreationFailed;
        if (!objc.addPointerIvar(target_class, target_ivar)) return error.ObjectiveCClassCreationFailed;
        const methods = .{
            .{ "fridayBuild:", &targetBuild },
            .{ "fridayShowLocked:", &targetShowLocked },
            .{ "fridaySetPreferredFrame:", &targetSetPreferredFrame },
            .{ "fridayUpdateMeter:", &targetUpdateMeter },
            .{ "fridayShowTranscribing:", &targetShowTranscribing },
            .{ "fridayHide:", &targetHide },
            .{ "fridayOrderOut:", &targetOrderOut },
            .{ "fridayRunProbe:", &targetRunProbe },
            .{ "fridayTeardown:", &targetTeardown },
            .{ "fridayStop:", &targetStop },
            .{ "fridayDismiss:", &targetDismiss },
            .{ "fridayCancel:", &targetCancel },
            .{ "fridayTick:", &targetTick },
            .{ "fridayPanelMoved:", &targetPanelMoved },
            .{ "fridayAccessibilityDisplayChanged:", &targetAccessibilityChanged },
        };
        inline for (methods) |method| {
            if (!objc.addMethod(target_class, objc.selector(method[0]), method[1], "v@:@")) return error.ObjectiveCClassCreationFailed;
        }
        if (!objc.addMethod(target_class, objc.selector("observeValueForKeyPath:ofObject:change:context:"), &targetObserveAppearance, "v@:@@@^v")) return error.ObjectiveCClassCreationFailed;
        objc.registerClassPair(target_class);
    }
    return .{ .panel = panel_class, .target = target_class };
}

fn panelCanBecomeKey(_: Id, _: Sel) callconv(.c) bool {
    return true;
}
fn panelCanBecomeMain(_: Id, _: Sel) callconv(.c) bool {
    return false;
}

fn stateFor(target: Id) ?*State {
    return objc.getPointerIvar(State, target, target_ivar);
}
fn targetBuild(target: Id, _: Sel, _: Id) callconv(.c) void {
    const state = stateFor(target) orelse return;
    state.build_ok = state.build();
}
fn targetShowLocked(target: Id, _: Sel, payload: Id) callconv(.c) void {
    const state = stateFor(target) orelse return;
    const locked_number = objc.send1(Id, NSUInteger, payload, objc.selector("objectAtIndex:"), 0);
    const elapsed_number = objc.send1(Id, NSUInteger, payload, objc.selector("objectAtIndex:"), 1);
    state.showLocked(objc.send0(bool, locked_number, objc.selector("boolValue")), objc.send0(u64, elapsed_number, objc.selector("unsignedLongLongValue")));
}
fn targetSetPreferredFrame(target: Id, _: Sel, value: Id) callconv(.c) void {
    const state = stateFor(target) orelse return;
    state.preferred_frame = if (value) |_| objc.send0(Rect, value, objc.selector("rectValue")) else null;
}
fn targetUpdateMeter(target: Id, _: Sel, payload: Id) callconv(.c) void {
    const state = stateFor(target) orelse return;
    const level_number = objc.send1(Id, NSUInteger, payload, objc.selector("objectAtIndex:"), 0);
    const elapsed_number = objc.send1(Id, NSUInteger, payload, objc.selector("objectAtIndex:"), 1);
    state.updateMeter(objc.send0(NSUInteger, level_number, objc.selector("unsignedIntegerValue")), objc.send0(u64, elapsed_number, objc.selector("unsignedLongLongValue")));
}
fn targetShowTranscribing(target: Id, _: Sel, _: Id) callconv(.c) void {
    if (stateFor(target)) |state| state.showTranscribing();
}
fn targetHide(target: Id, _: Sel, _: Id) callconv(.c) void {
    if (stateFor(target)) |state| state.hide();
}
fn targetOrderOut(target: Id, _: Sel, _: Id) callconv(.c) void {
    if (stateFor(target)) |state| state.orderOutNow();
}
fn targetRunProbe(target: Id, _: Sel, _: Id) callconv(.c) void {
    if (stateFor(target)) |state| state.probe = state.runProbe();
}
fn targetTeardown(target: Id, _: Sel, _: Id) callconv(.c) void {
    if (stateFor(target)) |state| state.teardown();
}
fn targetStop(target: Id, _: Sel, _: Id) callconv(.c) void {
    if (stateFor(target)) |state| state.performAction(.stop);
}
fn targetDismiss(target: Id, _: Sel, _: Id) callconv(.c) void {
    if (stateFor(target)) |state| state.performAction(.dismiss);
}
fn targetCancel(target: Id, _: Sel, _: Id) callconv(.c) void {
    if (stateFor(target)) |state| state.performAction(.cancel);
}
fn targetTick(target: Id, _: Sel, _: Id) callconv(.c) void {
    if (stateFor(target)) |state| state.tick();
}
fn targetPanelMoved(target: Id, _: Sel, _: Id) callconv(.c) void {
    if (stateFor(target)) |state| state.panelMoved();
}
fn targetAccessibilityChanged(target: Id, _: Sel, _: Id) callconv(.c) void {
    if (stateFor(target)) |state| state.updateVisualStyle();
}
fn targetObserveAppearance(target: Id, _: Sel, _: Id, _: Id, _: Id, _: ?*anyopaque) callconv(.c) void {
    if (stateFor(target)) |state| state.updateVisualStyle();
}

fn onMainThread() bool {
    return objc.send0(bool, objc.class("NSThread"), objc.selector("isMainThread"));
}
fn performOnMain(target: Id, operation: [*:0]const u8, payload: Id) void {
    objc.send3(void, Sel, Id, bool, target, objc.selector("performSelectorOnMainThread:withObject:waitUntilDone:"), objc.selector(operation), payload, true);
}
fn performOnMainAsync(target: Id, operation: [*:0]const u8, payload: Id) void {
    objc.send3(void, Sel, Id, bool, target, objc.selector("performSelectorOnMainThread:withObject:waitUntilDone:"), objc.selector(operation), payload, false);
}
fn pairPayload(first: u64, second: u64) Id {
    const array = objc.send1(Id, NSUInteger, objc.send0(Id, objc.class("NSMutableArray"), objc.selector("alloc")), objc.selector("initWithCapacity:"), 2);
    const first_number = objc.send1(Id, u64, objc.send0(Id, objc.class("NSNumber"), objc.selector("alloc")), objc.selector("initWithUnsignedLongLong:"), first);
    const second_number = objc.send1(Id, u64, objc.send0(Id, objc.class("NSNumber"), objc.selector("alloc")), objc.selector("initWithUnsignedLongLong:"), second);
    objc.send1(void, Id, array, objc.selector("addObject:"), first_number);
    objc.send1(void, Id, array, objc.selector("addObject:"), second_number);
    objc.release(first_number);
    objc.release(second_number);
    return array;
}

const State = struct {
    allocator: std.mem.Allocator,
    sink: EventSink,
    panel_class: objc.Class,
    target: Id = null,
    panel: Id = null,
    effect_view: Id = null,
    label: Id = null,
    status_dot: Id = null,
    bars: [5]Id = @splat(null),
    stop_button: Id = null,
    dismiss_button: Id = null,
    cancel_button: Id = null,
    timer: Id = null,
    shown_at: Id = null,
    preferred_frame: ?ScreenFrame = null,
    restored_position: bool = false,
    build_ok: bool = false,
    appearance_observer_registered: bool = false,
    mode: Mode = .held,
    elapsed_seed: u64 = 0,
    last_elapsed_second: u64 = std.math.maxInt(u64),
    meter_clock_synced: bool = false,
    smoothed_amplitude: CGFloat = 0,
    transcribing_phase: usize = 0,
    last_action: Action = .none,
    probe: ProbeSnapshot = .{},
    services_mutex: Mutex = .{},
    services: ?native_sdk.platform.PlatformServices = null,

    fn build(self: *State) bool {
        const panel_alloc = objc.send0(Id, self.panel_class, objc.selector("alloc"));
        self.panel = objc.send4(Id, Rect, NSUInteger, NSUInteger, bool, panel_alloc, objc.selector("initWithContentRect:styleMask:backing:defer:"), Rect.init(0, 0, panel_width, panel_height), style_nonactivating_panel, backing_buffered, false);
        if (self.panel == null) return false;

        objc.send1(void, NSInteger, self.panel, objc.selector("setLevel:"), @as(NSInteger, CGWindowLevelForKey(floating_window_level_key)));
        objc.send1(void, bool, self.panel, objc.selector("setOpaque:"), false);
        objc.send1(void, Id, self.panel, objc.selector("setBackgroundColor:"), objc.send0(Id, objc.class("NSColor"), objc.selector("clearColor")));
        objc.send1(void, bool, self.panel, objc.selector("setHasShadow:"), true);
        objc.send1(void, bool, self.panel, objc.selector("setHidesOnDeactivate:"), false);
        objc.send1(void, bool, self.panel, objc.selector("setBecomesKeyOnlyIfNeeded:"), true);
        objc.send1(void, bool, self.panel, objc.selector("setMovableByWindowBackground:"), true);
        objc.send1(void, NSUInteger, self.panel, objc.selector("setCollectionBehavior:"), collection_all_spaces | collection_fullscreen_auxiliary);
        setAccessibilityLabel(self.panel, "Friday dictation controls");

        const autosave = objc.nsString(autosave_name);
        self.restored_position = objc.send2(bool, Id, bool, self.panel, objc.selector("setFrameUsingName:force:"), autosave, false);
        objc.release(autosave);

        const view_alloc = objc.send0(Id, objc.class("NSVisualEffectView"), objc.selector("alloc"));
        self.effect_view = objc.send1(Id, Rect, view_alloc, objc.selector("initWithFrame:"), Rect.init(0, 0, panel_width, panel_height));
        if (self.effect_view == null) return false;
        objc.send1(void, NSUInteger, self.effect_view, objc.selector("setAutoresizingMask:"), autoresize_width | autoresize_height);
        objc.send1(void, NSInteger, self.effect_view, objc.selector("setState:"), visual_effect_state_active);
        objc.send1(void, bool, self.effect_view, objc.selector("setWantsLayer:"), true);
        const effect_layer = objc.send0(Id, self.effect_view, objc.selector("layer"));
        objc.send1(void, CGFloat, effect_layer, objc.selector("setCornerRadius:"), 12);
        objc.send1(void, bool, effect_layer, objc.selector("setMasksToBounds:"), true);
        objc.send1(void, Id, self.panel, objc.selector("setContentView:"), self.effect_view);
        objc.release(self.effect_view);

        self.status_dot = makeView(Rect.init(13, 22, 8, 8));
        if (self.status_dot == null) return false;
        objc.send1(void, CGFloat, objc.send0(Id, self.status_dot, objc.selector("layer")), objc.selector("setCornerRadius:"), 2);
        addSubview(self.effect_view, self.status_dot);

        const initial_heights = [_]CGFloat{ 6, 12, 18, 10, 7 };
        for (&self.bars, initial_heights, 0..) |*slot, height, index| {
            slot.* = makeView(Rect.init(31 + @as(CGFloat, @floatFromInt(index)) * 6, 26 - height / 2, 3, height));
            if (slot.* == null) return false;
            objc.send1(void, CGFloat, objc.send0(Id, slot.*, objc.selector("layer")), objc.selector("setCornerRadius:"), 1.5);
            addSubview(self.effect_view, slot.*);
        }

        const initial_label = objc.nsString("Listening 0:00");
        self.label = objc.retain(objc.send1(Id, Id, objc.class("NSTextField"), objc.selector("labelWithString:"), initial_label));
        objc.release(initial_label);
        if (self.label == null) return false;
        const digit_font = objc.send2(Id, CGFloat, CGFloat, objc.class("NSFont"), objc.selector("monospacedDigitSystemFontOfSize:weight:"), 12, 0.3);
        objc.send1(void, Id, self.label, objc.selector("setFont:"), digit_font);
        objc.send1(void, Rect, self.label, objc.selector("setFrame:"), Rect.init(67, 17, 96, 18));
        objc.send1(void, NSInteger, self.label, objc.selector("setLineBreakMode:"), line_break_truncating_tail);
        setAccessibilityLabel(self.label, "Recording elapsed time");
        addSubview(self.effect_view, self.label);

        self.stop_button = makeButton("Stop", self.target, "fridayStop:", Rect.init(158, 12, 48, 28), "Stop recording", null);
        self.dismiss_button = makeButton("–", self.target, "fridayDismiss:", Rect.init(206, 12, 26, 28), "Hide recording capsule", .{ .size = 16, .weight = 0.23 });
        self.cancel_button = makeButton("×", self.target, "fridayCancel:", Rect.init(234, 12, 26, 28), "Cancel dictation", .{ .size = 16, .weight = 0.23 });
        if (self.stop_button == null or self.dismiss_button == null or self.cancel_button == null) return false;
        addSubview(self.effect_view, self.stop_button);
        addSubview(self.effect_view, self.dismiss_button);
        addSubview(self.effect_view, self.cancel_button);

        const center = objc.send0(Id, objc.class("NSNotificationCenter"), objc.selector("defaultCenter"));
        const move_name = objc.nsString("NSWindowDidMoveNotification");
        objc.send4(void, Id, Sel, Id, Id, center, objc.selector("addObserver:selector:name:object:"), self.target, objc.selector("fridayPanelMoved:"), move_name, self.panel);
        objc.release(move_name);
        const workspace = objc.send0(Id, objc.class("NSWorkspace"), objc.selector("sharedWorkspace"));
        const workspace_center = objc.send0(Id, workspace, objc.selector("notificationCenter"));
        const display_name = objc.nsString("NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification");
        objc.send4(void, Id, Sel, Id, Id, workspace_center, objc.selector("addObserver:selector:name:object:"), self.target, objc.selector("fridayAccessibilityDisplayChanged:"), display_name, null);
        objc.release(display_name);
        const app = objc.send0(Id, objc.class("NSApplication"), objc.selector("sharedApplication"));
        const appearance_key = objc.nsString("effectiveAppearance");
        objc.send4(void, Id, Id, NSUInteger, ?*anyopaque, app, objc.selector("addObserver:forKeyPath:options:context:"), self.target, appearance_key, 0, null);
        objc.release(appearance_key);
        self.appearance_observer_registered = true;

        self.updateVisualStyle();
        self.applyAmplitude(0, false);
        return true;
    }

    fn updateVisualStyle(self: *State) void {
        if (self.effect_view == null) return;
        const workspace = objc.send0(Id, objc.class("NSWorkspace"), objc.selector("sharedWorkspace"));
        const reduce_transparency = objc.send0(bool, workspace, objc.selector("accessibilityDisplayShouldReduceTransparency"));
        const increase_contrast = objc.send0(bool, workspace, objc.selector("accessibilityDisplayShouldIncreaseContrast"));
        objc.send1(void, NSInteger, self.effect_view, objc.selector("setMaterial:"), if (reduce_transparency) material_window_background else material_hud_window);
        const layer = objc.send0(Id, self.effect_view, objc.selector("layer"));
        objc.send1(void, CGFloat, layer, objc.selector("setBorderWidth:"), if (increase_contrast) 1.5 else 0.5);
        const separator = objc.send0(Id, objc.class("NSColor"), objc.selector("separatorColor"));
        const border = objc.send1(Id, CGFloat, separator, objc.selector("colorWithAlphaComponent:"), if (increase_contrast) 1 else 0.55);
        const border_color = objc.send0(?*anyopaque, border, objc.selector("CGColor"));
        objc.send1(void, ?*anyopaque, layer, objc.selector("setBorderColor:"), border_color);

        self.updateSignalStyle();
    }

    fn updateSignalStyle(self: *State) void {
        const workspace = objc.send0(Id, objc.class("NSWorkspace"), objc.selector("sharedWorkspace"));
        const reduce_transparency = objc.send0(bool, workspace, objc.selector("accessibilityDisplayShouldReduceTransparency"));
        const appearance = objc.send0(Id, self.effect_view, objc.selector("effectiveAppearance"));
        const appearance_name = if (appearance != null) objc.send0(Id, appearance, objc.selector("name")) else null;
        var appearance_buffer: [64]u8 = undefined;
        const appearance_bytes = if (appearance_name != null) objc.copyUtf8Into(appearance_name, &appearance_buffer) else "";
        const dark_appearance = std.mem.indexOf(u8, appearance_bytes, "Dark") != null;
        const bright_live_signal = !reduce_transparency or dark_appearance;
        const signal = if (self.mode == .transcribing)
            objc.send0(Id, objc.class("NSColor"), objc.selector("labelColor"))
        else if (bright_live_signal)
            objc.send4(Id, CGFloat, CGFloat, CGFloat, CGFloat, objc.class("NSColor"), objc.selector("colorWithSRGBRed:green:blue:alpha:"), 0.745, 0.949, 0.392, 1)
        else
            objc.send4(Id, CGFloat, CGFloat, CGFloat, CGFloat, objc.class("NSColor"), objc.selector("colorWithSRGBRed:green:blue:alpha:"), 0.302, 0.486, 0.059, 1);
        const signal_color = objc.send0(?*anyopaque, signal, objc.selector("CGColor"));
        objc.send1(void, ?*anyopaque, objc.send0(Id, self.status_dot, objc.selector("layer")), objc.selector("setBackgroundColor:"), signal_color);
        for (self.bars) |bar| objc.send1(void, ?*anyopaque, objc.send0(Id, bar, objc.selector("layer")), objc.selector("setBackgroundColor:"), signal_color);
    }

    fn linearized(component: CGFloat) CGFloat {
        return if (component <= 0.04045) component / 12.92 else std.math.pow(CGFloat, (component + 0.055) / 1.055, 2.4);
    }

    fn luminance(red: CGFloat, green: CGFloat, blue: CGFloat) CGFloat {
        return 0.2126 * linearized(red) + 0.7152 * linearized(green) + 0.0722 * linearized(blue);
    }

    fn signalContrastContract() bool {
        const bright_luminance = luminance(0.745, 0.949, 0.392);
        const dark_luminance = luminance(0.302, 0.486, 0.059);
        const bright_on_black = (bright_luminance + 0.05) / 0.05;
        const dark_on_white = 1.05 / (dark_luminance + 0.05);
        return bright_on_black >= 4.5 and dark_on_white >= 4.5;
    }

    fn position(self: *State) void {
        if (self.panel == null or objc.send0(bool, self.panel, objc.selector("isVisible")) or self.restored_position) return;
        var visible: Rect = undefined;
        if (self.preferred_frame) |frame| {
            visible = frame;
        } else {
            var screen = objc.send0(Id, objc.class("NSScreen"), objc.selector("mainScreen"));
            if (screen == null) {
                const screens = objc.send0(Id, objc.class("NSScreen"), objc.selector("screens"));
                screen = objc.send0(Id, screens, objc.selector("firstObject"));
            }
            if (screen == null) return;
            visible = objc.send0(Rect, screen, objc.selector("visibleFrame"));
        }
        var frame = objc.send0(Rect, self.panel, objc.selector("frame"));
        frame.origin.x = visible.origin.x + (visible.size.width - frame.size.width) / 2;
        frame.origin.y = visible.origin.y + 36;
        objc.send2(void, Rect, bool, self.panel, objc.selector("setFrame:display:"), frame, false);
    }

    fn showLocked(self: *State, locked: bool, elapsed: u64) void {
        self.position();
        const was_visible = objc.send0(bool, self.panel, objc.selector("isVisible"));
        self.cancelScheduledHide();
        self.mode = if (locked) .locked else .held;
        self.updateSignalStyle();
        setHidden(self.stop_button, !locked);
        setHidden(self.cancel_button, false);
        setHidden(self.dismiss_button, false);
        self.elapsed_seed = elapsed;
        self.last_elapsed_second = std.math.maxInt(u64);
        self.meter_clock_synced = false;
        self.smoothed_amplitude = 0;
        self.replaceShownAt();
        self.updateElapsed(elapsed);
        self.replaceTimer();
        if (!was_visible and !self.reduceMotion()) objc.send1(void, CGFloat, self.panel, objc.selector("setAlphaValue:"), 0);
        objc.send0(void, self.panel, objc.selector("orderFrontRegardless"));
        self.reveal(was_visible);
    }
    fn replaceShownAt(self: *State) void {
        if (self.shown_at != null) objc.release(self.shown_at);
        self.shown_at = objc.retain(objc.send0(Id, objc.class("NSDate"), objc.selector("date")));
    }
    fn replaceTimer(self: *State) void {
        self.invalidateTimer();
        const interval: f64 = if (self.mode == .transcribing) 0.12 else 0.2;
        const timer = objc.send5(Id, f64, Id, Sel, Id, bool, objc.class("NSTimer"), objc.selector("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"), interval, self.target, objc.selector("fridayTick:"), null, true);
        self.timer = objc.retain(timer);
    }
    fn invalidateTimer(self: *State) void {
        if (self.timer) |timer| {
            objc.send0(void, timer, objc.selector("invalidate"));
            objc.release(timer);
            self.timer = null;
        }
    }
    fn tick(self: *State) void {
        if (self.mode == .transcribing) {
            self.applyTranscribingFrame();
            return;
        }
        if (self.shown_at == null) return;
        const interval = objc.send0(f64, self.shown_at, objc.selector("timeIntervalSinceNow"));
        const delta: u64 = @intFromFloat(@max(@as(f64, 0), @round(-interval * 1000)));
        self.updateElapsed(self.elapsed_seed +| delta);
    }
    fn updateElapsed(self: *State, elapsed: u64) void {
        const elapsed_second = elapsed / 1000;
        if (elapsed_second == self.last_elapsed_second) return;
        self.last_elapsed_second = elapsed_second;
        var buffer: [64]u8 = undefined;
        const prefix = if (self.mode == .locked) "Locked" else "Listening";
        const text = std.fmt.bufPrint(&buffer, "{s} {d}:{d:0>2}", .{ prefix, elapsed / 60000, (elapsed / 1000) % 60 }) catch return;
        setStringValue(self.label, text);
        setAccessibilityValue(self.label, text);
    }
    fn applyBarHeights(self: *State, heights: [5]CGFloat, animated: bool) void {
        const should_animate = animated and !self.reduceMotion();
        if (should_animate) {
            objc.send0(void, objc.class("NSAnimationContext"), objc.selector("beginGrouping"));
            const context = objc.send0(Id, objc.class("NSAnimationContext"), objc.selector("currentContext"));
            objc.send1(void, f64, context, objc.selector("setDuration:"), meter_animation_seconds);
        }
        for (self.bars, heights) |bar, height| {
            var frame = objc.send0(Rect, bar, objc.selector("frame"));
            frame.size.height = height;
            frame.origin.y = 26 - height / 2;
            const destination = if (should_animate) objc.send0(Id, bar, objc.selector("animator")) else bar;
            objc.send1(void, Rect, destination, objc.selector("setFrame:"), frame);
        }
        if (should_animate) objc.send0(void, objc.class("NSAnimationContext"), objc.selector("endGrouping"));
    }
    fn applyAmplitude(self: *State, amplitude: CGFloat, animated: bool) void {
        const bases = [_]CGFloat{ 4, 5, 6, 5, 4 };
        const ranges = [_]CGFloat{ 11, 21, 25, 19, 12 };
        var heights: [5]CGFloat = undefined;
        for (&heights, bases, ranges) |*height, base, range| height.* = base + range * amplitude;
        self.applyBarHeights(heights, animated);
    }
    fn applyTranscribingFrame(self: *State) void {
        const frames = [_][5]CGFloat{
            .{ 5, 9, 15, 10, 6 },
            .{ 6, 14, 9, 17, 7 },
            .{ 8, 11, 18, 9, 13 },
            .{ 5, 16, 10, 14, 6 },
        };
        self.applyBarHeights(frames[self.transcribing_phase % frames.len], true);
        self.transcribing_phase += 1;
    }
    fn updateMeter(self: *State, amplitude_milli: NSUInteger, elapsed: u64) void {
        if (self.mode == .transcribing) return;
        const raw = @min(@as(CGFloat, @floatFromInt(amplitude_milli)) / 650.0, 1.0);
        const target = @sqrt(raw);
        self.smoothed_amplitude += (target - self.smoothed_amplitude) * 0.42;
        self.applyAmplitude(self.smoothed_amplitude, true);
        if (!self.meter_clock_synced) {
            self.elapsed_seed = elapsed;
            self.replaceShownAt();
            self.last_elapsed_second = std.math.maxInt(u64);
            self.updateElapsed(elapsed);
            self.meter_clock_synced = true;
        }
    }
    fn showTranscribing(self: *State) void {
        self.position();
        const was_visible = objc.send0(bool, self.panel, objc.selector("isVisible"));
        self.cancelScheduledHide();
        self.invalidateTimer();
        self.mode = .transcribing;
        self.updateSignalStyle();
        setHidden(self.stop_button, true);
        setHidden(self.cancel_button, false);
        setHidden(self.dismiss_button, false);
        setStringValue(self.label, "Transcribing");
        setAccessibilityValue(self.label, "Transcribing locally");
        self.transcribing_phase = 0;
        self.applyTranscribingFrame();
        if (!self.reduceMotion()) self.replaceTimer();
        if (!was_visible and !self.reduceMotion()) objc.send1(void, CGFloat, self.panel, objc.selector("setAlphaValue:"), 0);
        objc.send0(void, self.panel, objc.selector("orderFrontRegardless"));
        self.reveal(was_visible);
    }
    fn hide(self: *State) void {
        self.invalidateTimer();
        if (self.panel == null or !objc.send0(bool, self.panel, objc.selector("isVisible"))) return;
        self.cancelScheduledHide();
        if (self.reduceMotion()) return self.orderOutNow();
        self.animateAlpha(0, fade_out_seconds);
        objc.send3(void, Sel, Id, f64, self.target, objc.selector("performSelector:withObject:afterDelay:"), objc.selector("fridayOrderOut:"), null, fade_out_seconds + 0.02);
    }
    fn reduceMotion(_: *State) bool {
        const workspace = objc.send0(Id, objc.class("NSWorkspace"), objc.selector("sharedWorkspace"));
        return objc.send0(bool, workspace, objc.selector("accessibilityDisplayShouldReduceMotion"));
    }
    fn cancelScheduledHide(self: *State) void {
        objc.send3(void, Id, Sel, Id, objc.class("NSObject"), objc.selector("cancelPreviousPerformRequestsWithTarget:selector:object:"), self.target, objc.selector("fridayOrderOut:"), null);
    }
    fn animateAlpha(self: *State, alpha: CGFloat, duration: f64) void {
        objc.send0(void, objc.class("NSAnimationContext"), objc.selector("beginGrouping"));
        const context = objc.send0(Id, objc.class("NSAnimationContext"), objc.selector("currentContext"));
        objc.send1(void, f64, context, objc.selector("setDuration:"), duration);
        const animator = objc.send0(Id, self.panel, objc.selector("animator"));
        objc.send1(void, CGFloat, animator, objc.selector("setAlphaValue:"), alpha);
        objc.send0(void, objc.class("NSAnimationContext"), objc.selector("endGrouping"));
    }
    fn reveal(self: *State, was_visible: bool) void {
        if (was_visible or self.reduceMotion()) {
            objc.send1(void, CGFloat, self.panel, objc.selector("setAlphaValue:"), 1);
            return;
        }
        self.animateAlpha(1, fade_in_seconds);
    }
    fn orderOutNow(self: *State) void {
        if (self.panel == null) return;
        objc.send1(void, Id, self.panel, objc.selector("orderOut:"), null);
        objc.send1(void, CGFloat, self.panel, objc.selector("setAlphaValue:"), 1);
    }
    fn panelMoved(self: *State) void {
        if (self.panel == null or !objc.send0(bool, self.panel, objc.selector("isVisible"))) return;
        const autosave = objc.nsString(autosave_name);
        _ = objc.send1(bool, Id, self.panel, objc.selector("saveFrameUsingName:"), autosave);
        objc.release(autosave);
        self.restored_position = true;
    }
    fn performAction(self: *State, action: Action) void {
        self.last_action = action;
        switch (action) {
            .stop => self.sink.emit(self.sink.context, "overlay_stop"),
            .dismiss => {
                self.hide();
                self.sink.emit(self.sink.context, "overlay_dismiss");
            },
            .cancel => self.sink.emit(self.sink.context, "overlay_cancel"),
            .none => {},
        }
    }

    fn runProbe(self: *State) ProbeSnapshot {
        const workspace = objc.send0(Id, objc.class("NSWorkspace"), objc.selector("sharedWorkspace"));
        const app = objc.send0(Id, objc.class("NSApplication"), objc.selector("sharedApplication"));
        const before_app = objc.send0(Id, workspace, objc.selector("frontmostApplication"));
        const before = if (before_app != null) objc.send0(i32, before_app, objc.selector("processIdentifier")) else 0;
        self.last_action = .none;
        self.showLocked(true, 1234);
        objc.send0(void, self.panel, objc.selector("displayIfNeeded"));

        var button_rect = objc.send0(Rect, self.stop_button, objc.selector("bounds"));
        button_rect = objc.send2(Rect, Rect, Id, self.stop_button, objc.selector("convertRect:toView:"), button_rect, null);
        button_rect = objc.send1(Rect, Rect, self.panel, objc.selector("convertRectToScreen:"), button_rect);
        var screen = objc.send0(Id, self.panel, objc.selector("screen"));
        if (screen == null) screen = objc.send0(Id, objc.class("NSScreen"), objc.selector("mainScreen"));
        if (screen != null) {
            const screen_frame = objc.send0(Rect, screen, objc.selector("frame"));
            button_rect.origin.y = screen_frame.origin.y + screen_frame.size.height - (button_rect.origin.y + button_rect.size.height);
        }

        var label_buffer: [96]u8 = undefined;
        const locked_label = objc.copyUtf8Into(objc.send0(Id, self.label, objc.selector("stringValue")), &label_buffer);
        const locked_ok = std.mem.startsWith(u8, locked_label, "Locked");
        self.updateMeter(500, 4321);
        const meter_label = objc.copyUtf8Into(objc.send0(Id, self.label, objc.selector("stringValue")), &label_buffer);
        const meter_ok = std.mem.eql(u8, meter_label, "Locked 0:04");
        const live_signal_applied = objc.send0(?*anyopaque, objc.send0(Id, self.status_dot, objc.selector("layer")), objc.selector("backgroundColor")) != null;
        self.showTranscribing();
        const transcribing_label = objc.copyUtf8Into(objc.send0(Id, self.label, objc.selector("stringValue")), &label_buffer);
        const transcribing_ok = std.mem.eql(u8, transcribing_label, "Transcribing");
        const controls_correct = objc.send0(bool, self.stop_button, objc.selector("isHidden")) and !objc.send0(bool, self.cancel_button, objc.selector("isHidden")) and !objc.send0(bool, self.dismiss_button, objc.selector("isHidden"));
        const reduced_motion_contract = if (self.reduceMotion()) self.timer == null else self.timer != null;
        const transcribing_signal_applied = objc.send0(?*anyopaque, objc.send0(Id, self.status_dot, objc.selector("layer")), objc.selector("backgroundColor")) != null;
        const signal_contract = live_signal_applied and transcribing_signal_applied and signalContrastContract();

        const reduce_transparency = objc.send0(bool, workspace, objc.selector("accessibilityDisplayShouldReduceTransparency"));
        const increase_contrast = objc.send0(bool, workspace, objc.selector("accessibilityDisplayShouldIncreaseContrast"));
        const layer = objc.send0(Id, self.effect_view, objc.selector("layer"));
        const material = objc.send0(NSInteger, self.effect_view, objc.selector("material"));
        const border_width = objc.send0(CGFloat, layer, objc.selector("borderWidth"));
        const appearance_contract = material == (if (reduce_transparency) material_window_background else material_hud_window) and border_width == (if (increase_contrast) @as(CGFloat, 1.5) else @as(CGFloat, 0.5)) and signal_contract;

        self.performAction(.dismiss);
        self.orderOutNow();
        const after_app = objc.send0(Id, workspace, objc.selector("frontmostApplication"));
        const after = if (after_app != null) objc.send0(i32, after_app, objc.selector("processIdentifier")) else 0;
        const friday_active = objc.send0(bool, app, objc.selector("isActive"));
        return .{
            .ok = before != 0 and !friday_active,
            .source_pid = before,
            .frontmost_pid = after,
            .friday_active = friday_active,
            .states_complete = locked_ok and meter_ok and transcribing_ok and controls_correct,
            .dismiss_contract = !objc.send0(bool, self.panel, objc.selector("isVisible")) and self.last_action == .dismiss,
            .appearance_contract = appearance_contract,
            .reduced_motion_contract = reduced_motion_contract,
            .button_rect = button_rect,
        };
    }

    fn teardown(self: *State) void {
        self.invalidateTimer();
        if (self.shown_at != null) {
            objc.release(self.shown_at);
            self.shown_at = null;
        }
        const center = objc.send0(Id, objc.class("NSNotificationCenter"), objc.selector("defaultCenter"));
        objc.send1(void, Id, center, objc.selector("removeObserver:"), self.target);
        const workspace = objc.send0(Id, objc.class("NSWorkspace"), objc.selector("sharedWorkspace"));
        const workspace_center = objc.send0(Id, workspace, objc.selector("notificationCenter"));
        objc.send1(void, Id, workspace_center, objc.selector("removeObserver:"), self.target);
        if (self.appearance_observer_registered) {
            const app = objc.send0(Id, objc.class("NSApplication"), objc.selector("sharedApplication"));
            const appearance_key = objc.nsString("effectiveAppearance");
            objc.send2(void, Id, Id, app, objc.selector("removeObserver:forKeyPath:"), self.target, appearance_key);
            objc.release(appearance_key);
            self.appearance_observer_registered = false;
        }
        if (self.stop_button != null) objc.send1(void, Id, self.stop_button, objc.selector("setTarget:"), null);
        if (self.dismiss_button != null) objc.send1(void, Id, self.dismiss_button, objc.selector("setTarget:"), null);
        if (self.cancel_button != null) objc.send1(void, Id, self.cancel_button, objc.selector("setTarget:"), null);
        if (self.panel != null) {
            objc.send1(void, Id, self.panel, objc.selector("orderOut:"), null);
            objc.release(self.panel);
            self.panel = null;
        }
    }
};

const ButtonFont = struct { size: CGFloat, weight: CGFloat };
fn makeView(frame: Rect) Id {
    const view = objc.send1(Id, Rect, objc.send0(Id, objc.class("NSView"), objc.selector("alloc")), objc.selector("initWithFrame:"), frame);
    objc.send1(void, bool, view, objc.selector("setWantsLayer:"), true);
    return view;
}
fn makeButton(title_bytes: []const u8, target: Id, action: [*:0]const u8, frame: Rect, accessibility: []const u8, font: ?ButtonFont) Id {
    const title = objc.nsString(title_bytes);
    const button = objc.send3(Id, Id, Id, Sel, objc.class("NSButton"), objc.selector("buttonWithTitle:target:action:"), title, target, objc.selector(action));
    objc.release(title);
    if (button == null) return null;
    objc.send1(void, NSUInteger, button, objc.selector("setBezelStyle:"), bezel_inline);
    objc.send1(void, bool, button, objc.selector("setRefusesFirstResponder:"), true);
    objc.send1(void, Rect, button, objc.selector("setFrame:"), frame);
    setAccessibilityLabel(button, accessibility);
    if (font) |spec| {
        const value = objc.send2(Id, CGFloat, CGFloat, objc.class("NSFont"), objc.selector("systemFontOfSize:weight:"), spec.size, spec.weight);
        objc.send1(void, Id, button, objc.selector("setFont:"), value);
    }
    return objc.retain(button);
}
fn addSubview(parent: Id, child: Id) void {
    objc.send1(void, Id, parent, objc.selector("addSubview:"), child);
    objc.release(child);
}
fn setHidden(view: Id, hidden: bool) void {
    objc.send1(void, bool, view, objc.selector("setHidden:"), hidden);
}
fn setStringValue(control: Id, bytes: []const u8) void {
    const value = objc.nsString(bytes);
    objc.send1(void, Id, control, objc.selector("setStringValue:"), value);
    objc.release(value);
}
fn setAccessibilityLabel(element: Id, bytes: []const u8) void {
    const value = objc.nsString(bytes);
    objc.send1(void, Id, element, objc.selector("setAccessibilityLabel:"), value);
    objc.release(value);
}
fn setAccessibilityValue(element: Id, bytes: []const u8) void {
    const value = objc.nsString(bytes);
    objc.send1(void, Id, element, objc.selector("setAccessibilityValue:"), value);
    objc.release(value);
}

/// A native AppKit panel is intentional here: Native SDK's passive-show window
/// option does not promise that clicking an interactive secondary window leaves
/// the process inactive. NSWindowStyleMaskNonactivatingPanel is that macOS
/// contract, while the SDK services remain available for future proven parity.
pub const Overlay = struct {
    state: *State,

    pub fn init(allocator: std.mem.Allocator, sink: EventSink) !Overlay {
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        const classes = try ensureClasses();
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{ .allocator = allocator, .sink = sink, .panel_class = classes.panel };
        state.target = objc.send0(Id, objc.send0(Id, classes.target, objc.selector("alloc")), objc.selector("init"));
        if (state.target == null) return error.OverlayInitializationFailed;
        errdefer objc.release(state.target);
        objc.setPointerIvar(state.target, target_ivar, state);
        if (onMainThread()) targetBuild(state.target, objc.selector("fridayBuild:"), null) else performOnMain(state.target, "fridayBuild:", null);
        if (!state.build_ok) {
            if (onMainThread()) state.teardown() else performOnMain(state.target, "fridayTeardown:", null);
            return error.OverlayInitializationFailed;
        }
        return .{ .state = state };
    }

    pub fn setServices(self: *Overlay, services: ?native_sdk.platform.PlatformServices) void {
        self.state.services_mutex.lock();
        defer self.state.services_mutex.unlock();
        self.state.services = services;
    }
    pub fn deinit(self: *Overlay) void {
        const state = self.state;
        if (onMainThread()) state.teardown() else performOnMain(state.target, "fridayTeardown:", null);
        objc.setPointerIvar(state.target, target_ivar, null);
        objc.release(state.target);
        const allocator = state.allocator;
        allocator.destroy(state);
        self.* = undefined;
    }
    pub fn showLocked(self: *Overlay, locked: bool, elapsed: u64) void {
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        if (onMainThread()) {
            self.state.showLocked(locked, elapsed);
        } else {
            const payload = pairPayload(@intFromBool(locked), elapsed);
            defer objc.release(payload);
            performOnMain(self.state.target, "fridayShowLocked:", payload);
        }
    }
    pub fn setPreferredScreenFrame(self: *Overlay, frame: ?ScreenFrame) void {
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        if (onMainThread()) {
            self.state.preferred_frame = frame;
        } else {
            const value = if (frame) |rect| objc.send1(Id, Rect, objc.class("NSValue"), objc.selector("valueWithRect:"), rect) else null;
            performOnMain(self.state.target, "fridaySetPreferredFrame:", value);
        }
    }
    pub fn updateMeter(self: *Overlay, level: usize, elapsed: u64) void {
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        if (onMainThread()) {
            self.state.updateMeter(level, elapsed);
        } else {
            const payload = pairPayload(level, elapsed);
            defer objc.release(payload);
            performOnMainAsync(self.state.target, "fridayUpdateMeter:", payload);
        }
    }
    pub fn showTranscribing(self: *Overlay) void {
        if (onMainThread()) self.state.showTranscribing() else performOnMain(self.state.target, "fridayShowTranscribing:", null);
    }
    pub fn hide(self: *Overlay) void {
        if (onMainThread()) self.state.hide() else performOnMain(self.state.target, "fridayHide:", null);
    }
    pub fn writeInteractionProbe(self: *Overlay, output: []u8) !usize {
        if (onMainThread()) self.state.probe = self.state.runProbe() else performOnMain(self.state.target, "fridayRunProbe:", null);
        const probe = self.state.probe;
        var writer = std.Io.Writer.fixed(output);
        try writer.print("{{\"ok\":{s},\"sourcePid\":{d},\"frontmostPid\":{d},\"fridayActive\":{s},\"style\":\"nonactivatingPanel\",\"positionAutosave\":\"FridayOverlayPosition\",\"statesComplete\":{s},\"dismissContract\":{s},\"appearanceContract\":{s},\"reducedMotionContract\":{s},\"buttonRect\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}}}", .{
            jsonBool(probe.ok), probe.source_pid, probe.frontmost_pid, jsonBool(probe.friday_active), jsonBool(probe.states_complete), jsonBool(probe.dismiss_contract), jsonBool(probe.appearance_contract), jsonBool(probe.reduced_motion_contract), probe.button_rect.origin.x, probe.button_rect.origin.y, probe.button_rect.size.width, probe.button_rect.size.height,
        });
        return writer.end;
    }
};

fn jsonBool(value: bool) []const u8 {
    return if (value) "true" else "false";
}
