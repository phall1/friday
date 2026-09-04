const std = @import("std");
const native_sdk = @import("native_sdk");
const objc = @import("objc.zig");

const Id = objc.Id;
const Sel = objc.Sel;
const CGFloat = f64;
const NSInteger = isize;
const NSUInteger = usize;

extern "c" fn CGWindowLevelForKey(key: i32) i32;
extern "c" fn NSAccessibilityPostNotificationWithUserInfo(element: Id, notification: Id, user_info: Id) void;
extern "c" var NSAccessibilityAnnouncementRequestedNotification: Id;
extern "c" var NSAccessibilityAnnouncementKey: Id;
extern "c" var NSAccessibilityPriorityKey: Id;
extern "c" var NSAccessibilityPressAction: Id;

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

const panel_width: CGFloat = 232;
const panel_height: CGFloat = 36;
const target_ivar: [*:0]const u8 = "_fridayOverlayState";
const autosave_name = "FridayOverlayPosition";

const style_nonactivating_panel: NSUInteger = 1 << 7;
const backing_buffered: NSUInteger = 2;
const collection_all_spaces: NSUInteger = 1 << 0;
const collection_fullscreen_auxiliary: NSUInteger = 1 << 8;
const autoresize_width: NSUInteger = 1 << 1;
const autoresize_height: NSUInteger = 1 << 4;
const visual_effect_state_active: NSInteger = 1;
const visual_effect_blending_behind_window: NSInteger = 0;
const visual_effect_blending_within_window: NSInteger = 1;
const material_window_background: NSInteger = 12;
const material_hud_window: NSInteger = 13;
const bezel_inline: NSUInteger = 15;
const line_break_truncating_tail: NSInteger = 4;
const floating_window_level_key: i32 = 5;
const modifier_option: NSUInteger = 1 << 19;
const accessibility_priority_medium: NSInteger = 50;
const fade_in_seconds: f64 = 0.14;
const fade_out_seconds: f64 = 0.12;
const bar_count = 7;
const bar_width: CGFloat = 3;
const bar_pitch: CGFloat = 5;
const bar_origin_x: CGFloat = 33;
const bar_min_height: CGFloat = 3;
const bar_max_height: CGFloat = 20;
const panel_center_y: CGFloat = panel_height / 2;
const tick_seconds: f64 = 1.0 / 30.0;
const meter_attack: CGFloat = 0.5;
const meter_release: CGFloat = 0.16;
const minimum_hit_size: CGFloat = 24;

const stop_frame = Rect.init(124, 6, 46, 24);
const dismiss_frame = Rect.init(174, 6, 24, 24);
const cancel_frame = Rect.init(202, 6, 24, 24);
const active_label_frame = Rect.init(72, 8, 50, 18);
const wide_label_frame = Rect.init(76, 8, 94, 18);

const Mode = enum { held, locked, transcribing, pasted, copied, failed };
const Action = enum { none, stop, dismiss, cancel, recover };

pub const TerminalOutcome = enum { pasted, copied, failed };

const SemanticState = enum { hidden, recording, locked_recording, transcribing, pasted, copied, failed };

const AnnouncementGate = struct {
    current: SemanticState = .hidden,
    count: usize = 0,

    fn transition(self: *AnnouncementGate, next: SemanticState) bool {
        if (next == .hidden) {
            self.current = .hidden;
            return false;
        }
        if (self.current == next) return false;
        self.current = next;
        self.count += 1;
        return true;
    }
};

const AppearancePolicy = struct {
    material: NSInteger,
    blending: NSInteger,
    border_width: CGFloat,
    recording_timer_interval: f64,
};

fn appearancePolicy(reduce_transparency: bool, increase_contrast: bool, reduce_motion: bool) AppearancePolicy {
    return .{
        .material = if (reduce_transparency) material_window_background else material_hud_window,
        .blending = if (reduce_transparency) visual_effect_blending_within_window else visual_effect_blending_behind_window,
        .border_width = if (increase_contrast) 1.5 else 0.5,
        .recording_timer_interval = if (reduce_motion) 1 else tick_seconds,
    };
}

fn animationsEnabled(reduce_motion: bool) bool {
    return !reduce_motion;
}

fn restingHeights() [bar_count]CGFloat {
    return .{ 4, 7, 10, 12, 10, 7, 4 };
}

const ProbeSnapshot = struct {
    ok: bool = false,
    source_pid: i32 = 0,
    frontmost_pid: i32 = 0,
    friday_active: bool = false,
    states_complete: bool = false,
    dismiss_contract: bool = false,
    appearance_contract: bool = false,
    reduced_motion_contract: bool = false,
    keyboard_contract: bool = false,
    voiceover_contract: bool = false,
    announcement_contract: bool = false,
    no_live_update_announcements: bool = false,
    non_color_state_contract: bool = false,
    hit_region_contract: bool = false,
    terminal_contract: bool = false,
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
            .{ "fridayShowTerminal:", &targetShowTerminal },
            .{ "fridayHide:", &targetHide },
            .{ "fridayOrderOut:", &targetOrderOut },
            .{ "fridayRunProbe:", &targetRunProbe },
            .{ "fridayTeardown:", &targetTeardown },
            .{ "fridayStop:", &targetStop },
            .{ "fridayDismiss:", &targetDismiss },
            .{ "fridayCancel:", &targetCancel },
            .{ "fridayRecover:", &targetRecover },
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
fn targetShowTerminal(target: Id, _: Sel, value: Id) callconv(.c) void {
    const state = stateFor(target) orelse return;
    const raw = objc.send0(NSUInteger, value, objc.selector("unsignedIntegerValue"));
    const outcome: TerminalOutcome = switch (raw) {
        @intFromEnum(TerminalOutcome.pasted) => .pasted,
        @intFromEnum(TerminalOutcome.copied) => .copied,
        @intFromEnum(TerminalOutcome.failed) => .failed,
        else => return,
    };
    state.showTerminal(outcome);
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
fn targetRecover(target: Id, _: Sel, _: Id) callconv(.c) void {
    if (stateFor(target)) |state| state.performAction(.recover);
}
fn targetTick(target: Id, _: Sel, _: Id) callconv(.c) void {
    if (stateFor(target)) |state| state.tick();
}
fn targetPanelMoved(target: Id, _: Sel, _: Id) callconv(.c) void {
    if (stateFor(target)) |state| state.panelMoved();
}
fn targetAccessibilityChanged(target: Id, _: Sel, _: Id) callconv(.c) void {
    if (stateFor(target)) |state| state.accessibilityDisplayChanged();
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
    bars: [bar_count]Id = @splat(null),
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
    meter_target: CGFloat = 0,
    smoothed_amplitude: CGFloat = 0,
    wave_phase: f64 = 0,
    last_action: Action = .none,
    announcement_gate: AnnouncementGate = .{},
    suppress_announcements: bool = false,
    probing_actions: bool = false,
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
        setAccessibilityValue(self.panel, "Recording");

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
        objc.send1(void, CGFloat, effect_layer, objc.selector("setCornerRadius:"), panel_height / 2);
        objc.send1(void, bool, effect_layer, objc.selector("setMasksToBounds:"), true);
        objc.send1(void, Id, self.panel, objc.selector("setContentView:"), self.effect_view);
        objc.release(self.effect_view);

        self.status_dot = makeView(Rect.init(15, panel_center_y - 4, 8, 8));
        if (self.status_dot == null) return false;
        objc.send1(void, CGFloat, objc.send0(Id, self.status_dot, objc.selector("layer")), objc.selector("setCornerRadius:"), 4);
        setAccessibilityElement(self.status_dot, false);
        addSubview(self.effect_view, self.status_dot);

        for (&self.bars, 0..) |*slot, index| {
            slot.* = makeView(Rect.init(bar_origin_x + @as(CGFloat, @floatFromInt(index)) * bar_pitch, panel_center_y - bar_min_height / 2, bar_width, bar_min_height));
            if (slot.* == null) return false;
            objc.send1(void, CGFloat, objc.send0(Id, slot.*, objc.selector("layer")), objc.selector("setCornerRadius:"), bar_width / 2);
            setAccessibilityElement(slot.*, false);
            addSubview(self.effect_view, slot.*);
        }

        const initial_label = objc.nsString("REC 0:00");
        self.label = objc.retain(objc.send1(Id, Id, objc.class("NSTextField"), objc.selector("labelWithString:"), initial_label));
        objc.release(initial_label);
        if (self.label == null) return false;
        const digit_font = objc.send2(Id, CGFloat, CGFloat, objc.class("NSFont"), objc.selector("monospacedDigitSystemFontOfSize:weight:"), 9, 0.3);
        objc.send1(void, Id, self.label, objc.selector("setFont:"), digit_font);
        objc.send1(void, Rect, self.label, objc.selector("setFrame:"), active_label_frame);
        objc.send1(void, NSInteger, self.label, objc.selector("setLineBreakMode:"), line_break_truncating_tail);
        // The timer remains visible, but it is deliberately outside the AX
        // tree. State changes are announced once from the panel instead of
        // exposing a value that changes every second while VoiceOver is idle.
        setAccessibilityElement(self.label, false);
        addSubview(self.effect_view, self.label);

        self.stop_button = makeButton("Stop", self.target, "fridayStop:", stop_frame, "Stop recording", "Press Return to stop and transcribe.", "\r", 0, null);
        self.dismiss_button = makeButton("–", self.target, "fridayDismiss:", dismiss_frame, "Hide recording capsule", "Press Option-H to hide without stopping.", "h", modifier_option, .{ .size = 15, .weight = 0.23 });
        self.cancel_button = makeButton("×", self.target, "fridayCancel:", cancel_frame, "Cancel dictation", "Press Escape to discard this dictation.", "\x1b", 0, .{ .size = 15, .weight = 0.23 });
        if (self.stop_button == null or self.dismiss_button == null or self.cancel_button == null) return false;
        addSubview(self.effect_view, self.stop_button);
        addSubview(self.effect_view, self.dismiss_button);
        addSubview(self.effect_view, self.cancel_button);
        objc.send1(void, Id, self.stop_button, objc.selector("setNextKeyView:"), self.dismiss_button);
        objc.send1(void, Id, self.dismiss_button, objc.selector("setNextKeyView:"), self.cancel_button);
        objc.send1(void, Id, self.cancel_button, objc.selector("setNextKeyView:"), self.stop_button);

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
        self.applyBarHeights(restingHeights());
        return true;
    }

    fn updateVisualStyle(self: *State) void {
        if (self.effect_view == null) return;
        const workspace = objc.send0(Id, objc.class("NSWorkspace"), objc.selector("sharedWorkspace"));
        const reduce_transparency = objc.send0(bool, workspace, objc.selector("accessibilityDisplayShouldReduceTransparency"));
        const increase_contrast = objc.send0(bool, workspace, objc.selector("accessibilityDisplayShouldIncreaseContrast"));
        const policy = appearancePolicy(reduce_transparency, increase_contrast, self.reduceMotion());
        objc.send1(void, NSInteger, self.effect_view, objc.selector("setMaterial:"), policy.material);
        objc.send1(void, NSInteger, self.effect_view, objc.selector("setBlendingMode:"), policy.blending);
        const layer = objc.send0(Id, self.effect_view, objc.selector("layer"));
        const background = if (reduce_transparency)
            objc.send0(Id, objc.class("NSColor"), objc.selector("windowBackgroundColor"))
        else
            objc.send0(Id, objc.class("NSColor"), objc.selector("clearColor"));
        objc.send1(void, ?*anyopaque, layer, objc.selector("setBackgroundColor:"), objc.send0(?*anyopaque, background, objc.selector("CGColor")));
        objc.send1(void, CGFloat, layer, objc.selector("setBorderWidth:"), policy.border_width);
        const separator = objc.send0(Id, objc.class("NSColor"), objc.selector("separatorColor"));
        const border = objc.send1(Id, CGFloat, separator, objc.selector("colorWithAlphaComponent:"), if (increase_contrast) 1 else 0.55);
        const border_color = objc.send0(?*anyopaque, border, objc.selector("CGColor"));
        objc.send1(void, ?*anyopaque, layer, objc.selector("setBorderColor:"), border_color);

        self.updateSignalStyle();
    }

    fn accessibilityDisplayChanged(self: *State) void {
        self.updateVisualStyle();
        if (!animationsEnabled(self.reduceMotion())) objc.send1(void, CGFloat, self.panel, objc.selector("setAlphaValue:"), 1);
        switch (self.mode) {
            .held, .locked => self.replaceTimer(),
            .transcribing => if (self.reduceMotion()) {
                self.invalidateTimer();
                self.applyBarHeights(restingHeights());
            } else if (self.timer == null) {
                self.applyTranscribingFrame();
                self.replaceTimer();
            },
            .pasted, .copied, .failed => {},
        }
    }

    fn updateSignalStyle(self: *State) void {
        // Recording reads as the platform's recording red on the dot with
        // adaptive label-colored bars; transcribing quiets both to the
        // secondary label tone. Adaptive colors keep contrast correct in
        // every appearance without a hand-tuned palette.
        const dot_color = switch (self.mode) {
            .held, .locked => objc.send0(Id, objc.class("NSColor"), objc.selector("systemRedColor")),
            .failed => objc.send0(Id, objc.class("NSColor"), objc.selector("systemOrangeColor")),
            else => objc.send0(Id, objc.class("NSColor"), objc.selector("secondaryLabelColor")),
        };
        const bar_color = if (self.mode == .held or self.mode == .locked)
            objc.send0(Id, objc.class("NSColor"), objc.selector("labelColor"))
        else
            objc.send0(Id, objc.class("NSColor"), objc.selector("secondaryLabelColor"));
        const dot_cg = objc.send0(?*anyopaque, dot_color, objc.selector("CGColor"));
        const bar_cg = objc.send0(?*anyopaque, bar_color, objc.selector("CGColor"));
        objc.send1(void, ?*anyopaque, objc.send0(Id, self.status_dot, objc.selector("layer")), objc.selector("setBackgroundColor:"), dot_cg);
        for (self.bars) |bar| objc.send1(void, ?*anyopaque, objc.send0(Id, bar, objc.selector("layer")), objc.selector("setBackgroundColor:"), bar_cg);
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
        self.configureStopButton(false);
        self.updateSignalStyle();
        for (self.bars) |bar| setHidden(bar, false);
        setHidden(self.stop_button, !locked);
        setHidden(self.cancel_button, false);
        setHidden(self.dismiss_button, false);
        setHidden(self.label, false);
        objc.send1(void, Rect, self.label, objc.selector("setFrame:"), active_label_frame);
        self.elapsed_seed = elapsed;
        self.last_elapsed_second = std.math.maxInt(u64);
        self.meter_clock_synced = false;
        self.meter_target = 0;
        self.smoothed_amplitude = 0;
        self.wave_phase = 0;
        self.applyBarHeights(restingHeights());
        self.replaceShownAt();
        self.updateElapsed(elapsed);
        self.replaceTimer();
        if (!was_visible and animationsEnabled(self.reduceMotion())) objc.send1(void, CGFloat, self.panel, objc.selector("setAlphaValue:"), 0);
        objc.send0(void, self.panel, objc.selector("orderFrontRegardless"));
        self.reveal(was_visible);
        if (locked) {
            self.announceSemantic(.locked_recording, "Locked recording. Stop or Cancel is available.");
        } else {
            self.announceSemantic(.recording, "Recording. Release the shortcut to transcribe, or choose Cancel.");
        }
    }
    fn replaceShownAt(self: *State) void {
        if (self.shown_at != null) objc.release(self.shown_at);
        self.shown_at = objc.retain(objc.send0(Id, objc.class("NSDate"), objc.selector("date")));
    }
    fn replaceTimer(self: *State) void {
        self.invalidateTimer();
        const interval = appearancePolicy(false, false, self.reduceMotion()).recording_timer_interval;
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
        switch (self.mode) {
            .transcribing => {
                if (animationsEnabled(self.reduceMotion())) self.applyTranscribingFrame();
                return;
            },
            .held, .locked => {},
            .pasted, .copied, .failed => return,
        }
        if (animationsEnabled(self.reduceMotion())) self.applyRecordingFrame();
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
        const prefix = if (self.mode == .locked) "LOCK" else "REC";
        const text = std.fmt.bufPrint(&buffer, "{s} {d}:{d:0>2}", .{ prefix, elapsed / 60000, (elapsed / 1000) % 60 }) catch return;
        setStringValue(self.label, text);
    }
    fn applyBarHeights(self: *State, heights: [bar_count]CGFloat) void {
        for (self.bars, heights) |bar, height| {
            var frame = objc.send0(Rect, bar, objc.selector("frame"));
            frame.size.height = height;
            frame.origin.y = panel_center_y - height / 2;
            objc.send1(void, Rect, bar, objc.selector("setFrame:"), frame);
        }
    }
    fn applyRecordingFrame(self: *State) void {
        // Fast attack / slow release into a per-bar organ pipe: each bar has
        // its own gain and a slow phase wobble so the meter reads as one
        // living instrument instead of five stepped rectangles. Silence
        // breathes at a low floor so the capsule never looks dead.
        const target = self.meter_target;
        const rate = if (target > self.smoothed_amplitude) meter_attack else meter_release;
        self.smoothed_amplitude += (target - self.smoothed_amplitude) * rate;
        self.wave_phase += tick_seconds * 6.0;
        const amplitude = self.smoothed_amplitude;
        const gains = [bar_count]CGFloat{ 0.5, 0.78, 1.0, 0.86, 1.0, 0.72, 0.46 };
        var heights: [bar_count]CGFloat = undefined;
        for (&heights, gains, 0..) |*height, gain, index| {
            const phase = self.wave_phase + @as(f64, @floatFromInt(index)) * 1.7;
            const wobble = 1.0 + 0.22 * @sin(phase);
            const breathe = 0.05 + 0.03 * @sin(self.wave_phase * 0.6 + @as(f64, @floatFromInt(index)) * 0.9);
            const level = @min(@max(amplitude * gain * wobble + breathe * (1.0 - amplitude), 0.0), 1.0);
            height.* = bar_min_height + (bar_max_height - bar_min_height) * @as(CGFloat, @floatCast(level));
        }
        self.applyBarHeights(heights);
    }
    fn applyTranscribingFrame(self: *State) void {
        // A single traveling wave, continuous at frame rate — no stepped
        // keyframes.
        self.wave_phase += tick_seconds * 5.0;
        var heights: [bar_count]CGFloat = undefined;
        for (&heights, 0..) |*height, index| {
            const phase = self.wave_phase - @as(f64, @floatFromInt(index)) * 0.85;
            const level = 0.5 + 0.5 * @sin(phase);
            height.* = bar_min_height + (bar_max_height - bar_min_height) * 0.75 * @as(CGFloat, @floatCast(level));
        }
        self.applyBarHeights(heights);
    }
    fn updateMeter(self: *State, amplitude_milli: NSUInteger, elapsed: u64) void {
        if (self.mode != .held and self.mode != .locked) return;
        const raw = @min(@as(CGFloat, @floatFromInt(amplitude_milli)) / 650.0, 1.0);
        self.meter_target = @sqrt(raw);
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
        self.configureStopButton(false);
        self.updateSignalStyle();
        for (self.bars) |bar| setHidden(bar, false);
        setHidden(self.stop_button, true);
        setHidden(self.cancel_button, false);
        setHidden(self.dismiss_button, false);
        setHidden(self.label, false);
        objc.send1(void, Rect, self.label, objc.selector("setFrame:"), wide_label_frame);
        setStringValue(self.label, "Transcribing");
        self.wave_phase = 0;
        if (!animationsEnabled(self.reduceMotion())) {
            self.applyBarHeights(restingHeights());
        } else {
            self.applyTranscribingFrame();
            self.replaceTimer();
        }
        if (!was_visible and animationsEnabled(self.reduceMotion())) objc.send1(void, CGFloat, self.panel, objc.selector("setAlphaValue:"), 0);
        objc.send0(void, self.panel, objc.selector("orderFrontRegardless"));
        self.reveal(was_visible);
        self.announceSemantic(.transcribing, "Transcribing locally. Cancel is available.");
    }

    fn showTerminal(self: *State, outcome: TerminalOutcome) void {
        self.position();
        const was_visible = objc.send0(bool, self.panel, objc.selector("isVisible"));
        self.cancelScheduledHide();
        self.invalidateTimer();
        self.mode = switch (outcome) {
            .pasted => .pasted,
            .copied => .copied,
            .failed => .failed,
        };
        self.updateSignalStyle();
        for (self.bars) |bar| setHidden(bar, true);
        setHidden(self.cancel_button, true);
        setHidden(self.dismiss_button, false);
        setHidden(self.label, false);
        switch (outcome) {
            .pasted => {
                setHidden(self.stop_button, true);
                objc.send1(void, Rect, self.label, objc.selector("setFrame:"), wide_label_frame);
                setStringValue(self.label, "Pasted");
            },
            .copied => {
                self.configureStopButton(true);
                setHidden(self.stop_button, false);
                objc.send1(void, Rect, self.label, objc.selector("setFrame:"), active_label_frame);
                setStringValue(self.label, "Copied");
            },
            .failed => {
                self.configureStopButton(true);
                setHidden(self.stop_button, false);
                objc.send1(void, Rect, self.label, objc.selector("setFrame:"), active_label_frame);
                setStringValue(self.label, "Failed");
            },
        }
        if (!was_visible and animationsEnabled(self.reduceMotion())) objc.send1(void, CGFloat, self.panel, objc.selector("setAlphaValue:"), 0);
        objc.send0(void, self.panel, objc.selector("orderFrontRegardless"));
        self.reveal(was_visible);
        switch (outcome) {
            .pasted => self.announceSemantic(.pasted, "Dictation pasted into the source app."),
            .copied => self.announceSemantic(.copied, "Dictation copied to the clipboard. Recover Paste Access is available."),
            .failed => self.announceSemantic(.failed, "Dictation failed. Open Friday for recovery."),
        }
    }
    fn configureStopButton(self: *State, recovery: bool) void {
        if (recovery) {
            setButtonTitle(self.stop_button, "Fix");
            objc.send1(void, Sel, self.stop_button, objc.selector("setAction:"), objc.selector("fridayRecover:"));
            if (self.mode == .copied) {
                setAccessibilityLabel(self.stop_button, "Recover paste access");
                setAccessibilityHelp(self.stop_button, "Press Return to open Friday's paste access recovery.");
            } else {
                setAccessibilityLabel(self.stop_button, "Open Friday for recovery");
                setAccessibilityHelp(self.stop_button, "Press Return to open Friday and recover from the failure.");
            }
        } else {
            setButtonTitle(self.stop_button, "Stop");
            objc.send1(void, Sel, self.stop_button, objc.selector("setAction:"), objc.selector("fridayStop:"));
            setAccessibilityLabel(self.stop_button, "Stop recording");
            setAccessibilityHelp(self.stop_button, "Press Return to stop and transcribe.");
        }
    }
    fn announceSemantic(self: *State, semantic: SemanticState, message: []const u8) void {
        if (!self.announcement_gate.transition(semantic)) return;
        setAccessibilityValue(self.panel, switch (semantic) {
            .recording => "Recording",
            .locked_recording => "Locked recording",
            .transcribing => "Transcribing",
            .pasted => "Pasted into source app",
            .copied => "Copied to clipboard; paste access recovery available",
            .failed => "Failed; recovery available",
            .hidden => "Hidden",
        });
        if (self.suppress_announcements) return;

        const announcement = objc.nsString(message);
        defer objc.release(announcement);
        const priority = objc.send1(Id, NSInteger, objc.class("NSNumber"), objc.selector("numberWithInteger:"), accessibility_priority_medium);
        const info = objc.send1(Id, NSUInteger, objc.send0(Id, objc.class("NSMutableDictionary"), objc.selector("alloc")), objc.selector("initWithCapacity:"), 2);
        defer objc.release(info);
        objc.send2(void, Id, Id, info, objc.selector("setObject:forKey:"), announcement, NSAccessibilityAnnouncementKey);
        objc.send2(void, Id, Id, info, objc.selector("setObject:forKey:"), priority, NSAccessibilityPriorityKey);
        NSAccessibilityPostNotificationWithUserInfo(self.panel, NSAccessibilityAnnouncementRequestedNotification, info);
    }
    fn hide(self: *State) void {
        self.invalidateTimer();
        if (self.panel == null or !objc.send0(bool, self.panel, objc.selector("isVisible"))) return;
        _ = self.announcement_gate.transition(.hidden);
        self.cancelScheduledHide();
        if (!animationsEnabled(self.reduceMotion())) return self.orderOutNow();
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
        if (was_visible or !animationsEnabled(self.reduceMotion())) {
            objc.send1(void, CGFloat, self.panel, objc.selector("setAlphaValue:"), 1);
            return;
        }
        self.animateAlpha(1, fade_in_seconds);
    }
    fn orderOutNow(self: *State) void {
        if (self.panel == null) return;
        _ = self.announcement_gate.transition(.hidden);
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
            .stop => if (!self.probing_actions) self.sink.emit(self.sink.context, "overlay_stop"),
            .dismiss => {
                self.hide();
                if (!self.probing_actions) self.sink.emit(self.sink.context, "overlay_dismiss");
            },
            .cancel => if (!self.probing_actions) self.sink.emit(self.sink.context, "overlay_cancel"),
            .recover => if (!self.probing_actions) self.sink.emit(self.sink.context, "overlay_recover"),
            .none => {},
        }
    }

    fn runProbe(self: *State) ProbeSnapshot {
        const workspace = objc.send0(Id, objc.class("NSWorkspace"), objc.selector("sharedWorkspace"));
        const app = objc.send0(Id, objc.class("NSApplication"), objc.selector("sharedApplication"));
        const before_app = objc.send0(Id, workspace, objc.selector("frontmostApplication"));
        const before = if (before_app != null) objc.send0(i32, before_app, objc.selector("processIdentifier")) else 0;
        self.suppress_announcements = true;
        self.probing_actions = true;
        defer {
            self.suppress_announcements = false;
            self.probing_actions = false;
            self.orderOutNow();
        }
        self.announcement_gate = .{};
        self.last_action = .none;
        self.showLocked(false, 1234);
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
        const held_label = objc.copyUtf8Into(objc.send0(Id, self.label, objc.selector("stringValue")), &label_buffer);
        const held_ok = std.mem.eql(u8, held_label, "REC 0:01");
        const announcement_after_held = self.announcement_gate.count;
        self.updateMeter(500, 4321);
        const meter_label = objc.copyUtf8Into(objc.send0(Id, self.label, objc.selector("stringValue")), &label_buffer);
        const meter_ok = std.mem.eql(u8, meter_label, "REC 0:04");
        self.tick();
        const no_live_update_announcements = announcement_after_held == 1 and self.announcement_gate.count == announcement_after_held;
        self.showLocked(false, 4321);
        const held_one_shot = self.announcement_gate.count == announcement_after_held;

        self.showLocked(true, 4321);
        const locked_label = objc.copyUtf8Into(objc.send0(Id, self.label, objc.selector("stringValue")), &label_buffer);
        const locked_ok = std.mem.eql(u8, locked_label, "LOCK 0:04");
        const hit_region_contract = controlHitRegion(self.effect_view, self.stop_button) and controlHitRegion(self.effect_view, self.dismiss_button) and controlHitRegion(self.effect_view, self.cancel_button);
        const keyboard_contract = buttonKeyboardContract(self.stop_button, "\r", 0) and buttonKeyboardContract(self.dismiss_button, "h", modifier_option) and buttonKeyboardContract(self.cancel_button, "\x1b", 0) and
            objc.send0(Id, self.stop_button, objc.selector("nextKeyView")) == self.dismiss_button and
            objc.send0(Id, self.dismiss_button, objc.selector("nextKeyView")) == self.cancel_button and
            objc.send0(Id, self.cancel_button, objc.selector("nextKeyView")) == self.stop_button;
        const voiceover_actions_exposed = buttonVoiceOverContract(self.stop_button) and buttonVoiceOverContract(self.dismiss_button) and buttonVoiceOverContract(self.cancel_button);
        const recording_timer_contract = self.timer != null;
        const live_signal_applied = objc.send0(?*anyopaque, objc.send0(Id, self.status_dot, objc.selector("layer")), objc.selector("backgroundColor")) != null;
        self.showTranscribing();
        const transcribing_label = objc.copyUtf8Into(objc.send0(Id, self.label, objc.selector("stringValue")), &label_buffer);
        const transcribing_ok = self.mode == .transcribing and !objc.send0(bool, self.label, objc.selector("isHidden")) and std.mem.eql(u8, transcribing_label, "Transcribing");
        const controls_correct = objc.send0(bool, self.stop_button, objc.selector("isHidden")) and !objc.send0(bool, self.cancel_button, objc.selector("isHidden")) and !objc.send0(bool, self.dismiss_button, objc.selector("isHidden"));
        const reduced_motion_contract = recording_timer_contract and if (self.reduceMotion()) self.timer == null else self.timer != null;
        const transcribing_signal_applied = objc.send0(?*anyopaque, objc.send0(Id, self.status_dot, objc.selector("layer")), objc.selector("backgroundColor")) != null;
        const signal_contract = live_signal_applied and transcribing_signal_applied;

        self.showTranscribing();
        const active_one_shot = self.announcement_gate.count == 3;
        self.showTerminal(.pasted);
        const pasted_label = objc.copyUtf8Into(objc.send0(Id, self.label, objc.selector("stringValue")), &label_buffer);
        const pasted_ok = std.mem.eql(u8, pasted_label, "Pasted") and objc.send0(bool, self.stop_button, objc.selector("isHidden"));
        self.showTerminal(.pasted);
        const pasted_one_shot = self.announcement_gate.count == 4;
        self.showTerminal(.copied);
        const copied_label = objc.copyUtf8Into(objc.send0(Id, self.label, objc.selector("stringValue")), &label_buffer);
        const copied_ok = std.mem.eql(u8, copied_label, "Copied") and !objc.send0(bool, self.stop_button, objc.selector("isHidden")) and buttonVoiceOverContract(self.stop_button);
        self.showTerminal(.failed);
        const failed_label = objc.copyUtf8Into(objc.send0(Id, self.label, objc.selector("stringValue")), &label_buffer);
        const failed_ok = std.mem.eql(u8, failed_label, "Failed") and !objc.send0(bool, self.stop_button, objc.selector("isHidden"));
        const announcement_contract = held_one_shot and active_one_shot and pasted_one_shot and self.announcement_gate.count == 6;
        const terminal_contract = pasted_ok and copied_ok and failed_ok;

        self.showLocked(true, 4321);
        const stop_pressed = performVoiceOverPress(self, self.stop_button, .stop);
        const cancel_pressed = performVoiceOverPress(self, self.cancel_button, .cancel);
        const dismiss_pressed = performVoiceOverPress(self, self.dismiss_button, .dismiss);
        self.orderOutNow();
        const dismiss_contract = !objc.send0(bool, self.panel, objc.selector("isVisible")) and self.last_action == .dismiss;
        self.showTerminal(.copied);
        const recover_pressed = performVoiceOverPress(self, self.stop_button, .recover);
        const voiceover_contract = voiceover_actions_exposed and stop_pressed and cancel_pressed and dismiss_pressed and recover_pressed;
        const timer_ignored = !objc.send0(bool, self.label, objc.selector("isAccessibilityElement"));
        var panel_value_buffer: [96]u8 = undefined;
        const panel_value = objc.copyUtf8Into(objc.send0(Id, self.panel, objc.selector("accessibilityValue")), &panel_value_buffer);
        const non_color_state_contract = timer_ignored and std.mem.eql(u8, panel_value, "Copied to clipboard; paste access recovery available");

        const reduce_transparency = objc.send0(bool, workspace, objc.selector("accessibilityDisplayShouldReduceTransparency"));
        const increase_contrast = objc.send0(bool, workspace, objc.selector("accessibilityDisplayShouldIncreaseContrast"));
        const policy = appearancePolicy(reduce_transparency, increase_contrast, self.reduceMotion());
        const layer = objc.send0(Id, self.effect_view, objc.selector("layer"));
        const material = objc.send0(NSInteger, self.effect_view, objc.selector("material"));
        const blending = objc.send0(NSInteger, self.effect_view, objc.selector("blendingMode"));
        const border_width = objc.send0(CGFloat, layer, objc.selector("borderWidth"));
        const appearance_contract = material == policy.material and blending == policy.blending and border_width == policy.border_width and signal_contract;

        const after_app = objc.send0(Id, workspace, objc.selector("frontmostApplication"));
        const after = if (after_app != null) objc.send0(i32, after_app, objc.selector("processIdentifier")) else 0;
        const friday_active = objc.send0(bool, app, objc.selector("isActive"));
        return .{
            .ok = before != 0 and before == after and !friday_active,
            .source_pid = before,
            .frontmost_pid = after,
            .friday_active = friday_active,
            .states_complete = held_ok and locked_ok and meter_ok and transcribing_ok and controls_correct,
            .dismiss_contract = dismiss_contract,
            .appearance_contract = appearance_contract,
            .reduced_motion_contract = reduced_motion_contract,
            .keyboard_contract = keyboard_contract,
            .voiceover_contract = voiceover_contract,
            .announcement_contract = announcement_contract,
            .no_live_update_announcements = no_live_update_announcements,
            .non_color_state_contract = non_color_state_contract,
            .hit_region_contract = hit_region_contract,
            .terminal_contract = terminal_contract,
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
fn makeButton(title_bytes: []const u8, target: Id, action: [*:0]const u8, frame: Rect, accessibility: []const u8, help: []const u8, key_equivalent: []const u8, key_modifiers: NSUInteger, font: ?ButtonFont) Id {
    const title = objc.nsString(title_bytes);
    const button = objc.send3(Id, Id, Id, Sel, objc.class("NSButton"), objc.selector("buttonWithTitle:target:action:"), title, target, objc.selector(action));
    objc.release(title);
    if (button == null) return null;
    objc.send1(void, NSUInteger, button, objc.selector("setBezelStyle:"), bezel_inline);
    objc.send1(void, bool, button, objc.selector("setRefusesFirstResponder:"), false);
    objc.send1(void, Rect, button, objc.selector("setFrame:"), frame);
    setAccessibilityElement(button, true);
    setAccessibilityLabel(button, accessibility);
    setAccessibilityHelp(button, help);
    const key = objc.nsString(key_equivalent);
    objc.send1(void, Id, button, objc.selector("setKeyEquivalent:"), key);
    objc.release(key);
    objc.send1(void, NSUInteger, button, objc.selector("setKeyEquivalentModifierMask:"), key_modifiers);
    if (font) |spec| {
        const value = objc.send2(Id, CGFloat, CGFloat, objc.class("NSFont"), objc.selector("systemFontOfSize:weight:"), spec.size, spec.weight);
        objc.send1(void, Id, button, objc.selector("setFont:"), value);
    }
    return objc.retain(button);
}
fn buttonKeyboardContract(button: Id, expected_key: []const u8, expected_modifiers: NSUInteger) bool {
    if (objc.send0(bool, button, objc.selector("refusesFirstResponder"))) return false;
    var buffer: [8]u8 = undefined;
    const key = objc.copyUtf8Into(objc.send0(Id, button, objc.selector("keyEquivalent")), &buffer);
    return std.mem.eql(u8, key, expected_key) and objc.send0(NSUInteger, button, objc.selector("keyEquivalentModifierMask")) == expected_modifiers;
}
fn buttonVoiceOverContract(button: Id) bool {
    if (!objc.send0(bool, button, objc.selector("isAccessibilityElement"))) return false;
    const actions = objc.send0(Id, button, objc.selector("accessibilityActionNames"));
    return actions != null and objc.send1(bool, Id, actions, objc.selector("containsObject:"), NSAccessibilityPressAction);
}
fn performVoiceOverPress(state: *State, button: Id, expected: Action) bool {
    state.last_action = .none;
    return objc.send0(bool, button, objc.selector("accessibilityPerformPress")) and state.last_action == expected;
}
fn controlHitRegion(parent: Id, button: Id) bool {
    const frame = objc.send0(Rect, button, objc.selector("frame"));
    if (frame.size.width < minimum_hit_size or frame.size.height < minimum_hit_size) return false;
    const center = Point{ .x = frame.origin.x + frame.size.width / 2, .y = frame.origin.y + frame.size.height / 2 };
    return objc.send1(Id, Point, parent, objc.selector("hitTest:"), center) == button;
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
fn setButtonTitle(button: Id, bytes: []const u8) void {
    const value = objc.nsString(bytes);
    objc.send1(void, Id, button, objc.selector("setTitle:"), value);
    objc.release(value);
}
fn setAccessibilityElement(element: Id, value: bool) void {
    objc.send1(void, bool, element, objc.selector("setAccessibilityElement:"), value);
}
fn setAccessibilityLabel(element: Id, bytes: []const u8) void {
    const value = objc.nsString(bytes);
    objc.send1(void, Id, element, objc.selector("setAccessibilityLabel:"), value);
    objc.release(value);
}
fn setAccessibilityHelp(element: Id, bytes: []const u8) void {
    const value = objc.nsString(bytes);
    objc.send1(void, Id, element, objc.selector("setAccessibilityHelp:"), value);
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
    pub fn showTerminal(self: *Overlay, outcome: TerminalOutcome) void {
        if (onMainThread()) {
            self.state.showTerminal(outcome);
        } else {
            const value = objc.send1(Id, NSUInteger, objc.class("NSNumber"), objc.selector("numberWithUnsignedInteger:"), @intFromEnum(outcome));
            performOnMain(self.state.target, "fridayShowTerminal:", value);
        }
    }
    pub fn hide(self: *Overlay) void {
        if (onMainThread()) self.state.hide() else performOnMain(self.state.target, "fridayHide:", null);
    }
    pub fn writeInteractionProbe(self: *Overlay, output: []u8) !usize {
        if (onMainThread()) self.state.probe = self.state.runProbe() else performOnMain(self.state.target, "fridayRunProbe:", null);
        const probe = self.state.probe;
        var writer = std.Io.Writer.fixed(output);
        try writer.print("{{\"ok\":{s},\"sourcePid\":{d},\"frontmostPid\":{d},\"fridayActive\":{s},\"style\":\"nonactivatingPanel\",\"positionAutosave\":\"FridayOverlayPosition\",\"statesComplete\":{s},\"dismissContract\":{s},\"appearanceContract\":{s},\"reducedMotionContract\":{s},\"keyboardContract\":{s},\"voiceOverContract\":{s},\"announcementContract\":{s},\"noLiveUpdateAnnouncements\":{s},\"nonColorStateContract\":{s},\"hitRegionContract\":{s},\"terminalContract\":{s},\"buttonRect\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}}}", .{
            jsonBool(probe.ok),
            probe.source_pid,
            probe.frontmost_pid,
            jsonBool(probe.friday_active),
            jsonBool(probe.states_complete),
            jsonBool(probe.dismiss_contract),
            jsonBool(probe.appearance_contract),
            jsonBool(probe.reduced_motion_contract),
            jsonBool(probe.keyboard_contract),
            jsonBool(probe.voiceover_contract),
            jsonBool(probe.announcement_contract),
            jsonBool(probe.no_live_update_announcements),
            jsonBool(probe.non_color_state_contract),
            jsonBool(probe.hit_region_contract),
            jsonBool(probe.terminal_contract),
            probe.button_rect.origin.x,
            probe.button_rect.origin.y,
            probe.button_rect.size.width,
            probe.button_rect.size.height,
        });
        return writer.end;
    }
};

fn jsonBool(value: bool) []const u8 {
    return if (value) "true" else "false";
}

test "semantic announcements occur once per production state transition" {
    var gate = AnnouncementGate{};
    try std.testing.expect(gate.transition(.recording));
    try std.testing.expect(!gate.transition(.recording));
    try std.testing.expect(gate.transition(.locked_recording));
    try std.testing.expect(!gate.transition(.locked_recording));
    try std.testing.expect(gate.transition(.transcribing));
    try std.testing.expect(!gate.transition(.transcribing));
    try std.testing.expect(gate.transition(.copied));
    try std.testing.expect(!gate.transition(.copied));
    try std.testing.expectEqual(@as(usize, 4), gate.count);
    try std.testing.expect(!gate.transition(.hidden));
    try std.testing.expect(gate.transition(.recording));
    try std.testing.expectEqual(@as(usize, 5), gate.count);
}

test "production capsule controls retain minimum point hit regions" {
    inline for (.{ stop_frame, dismiss_frame, cancel_frame }) |frame| {
        try std.testing.expect(frame.size.width >= minimum_hit_size);
        try std.testing.expect(frame.size.height >= minimum_hit_size);
        try std.testing.expect(frame.origin.x >= 0 and frame.origin.y >= 0);
        try std.testing.expect(frame.origin.x + frame.size.width <= panel_width);
        try std.testing.expect(frame.origin.y + frame.size.height <= panel_height);
    }
    try std.testing.expect(stop_frame.origin.x + stop_frame.size.width <= dismiss_frame.origin.x);
    try std.testing.expect(dismiss_frame.origin.x + dismiss_frame.size.width <= cancel_frame.origin.x);
}

test "appearance policy covers transparency contrast and motion settings" {
    const ordinary = appearancePolicy(false, false, false);
    try std.testing.expectEqual(material_hud_window, ordinary.material);
    try std.testing.expectEqual(visual_effect_blending_behind_window, ordinary.blending);
    try std.testing.expectEqual(@as(CGFloat, 0.5), ordinary.border_width);
    try std.testing.expect(animationsEnabled(false));
    try std.testing.expectEqual(tick_seconds, ordinary.recording_timer_interval);

    const accessible = appearancePolicy(true, true, true);
    try std.testing.expectEqual(material_window_background, accessible.material);
    try std.testing.expectEqual(visual_effect_blending_within_window, accessible.blending);
    try std.testing.expectEqual(@as(CGFloat, 1.5), accessible.border_width);
    try std.testing.expect(!animationsEnabled(true));
    try std.testing.expectEqual(@as(f64, 1), accessible.recording_timer_interval);
}
