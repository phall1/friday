//! Friday's type and geometry layer. The SDK still resolves live appearance,
//! contrast, motion, semantic colors, focus, and device scale.
const std = @import("std");
const canvas = @import("native_sdk").canvas;

const regular = canvas.min_registered_font_id;
const medium = regular + 1;
const semibold = regular + 2;

pub fn fonts(comptime Registration: type) [3]Registration {
    return .{
        .{ .id = regular, .name = "IBMPlexSans-Regular.ttf", .ttf = @embedFile("fonts/IBMPlexSans-Regular.ttf") },
        .{ .id = medium, .name = "IBMPlexSans-Medium.ttf", .ttf = @embedFile("fonts/IBMPlexSans-Medium.ttf") },
        .{ .id = semibold, .name = "IBMPlexSans-SemiBold.ttf", .ttf = @embedFile("fonts/IBMPlexSans-SemiBold.ttf") },
    };
}

pub fn refineTheme(base: canvas.DesignTokens, high_contrast: bool) canvas.DesignTokens {
    const styled = base.withOverrides(.{
        .typography = .{
            .font_id = regular,
            .medium_font_id = medium,
            .bold_font_id = semibold,
            .button_font_id = medium,
            .body_size = 14,
            .label_size = 13,
            .button_size = 13,
            .title_size = 20,
            .heading_size = 26,
        },
        .radius = .{ .sm = 3, .md = 4, .lg = 4, .xl = 6 },
    });
    if (high_contrast) return styled;
    return styled.withOverrides(.{ .controls = .{ .switch_control = .{
        .radius = 6,
        .background = canvas.Color.rgb8(118, 118, 118),
        .active_background = base.colors.text,
        .foreground = base.colors.background,
    } } });
}

pub fn testContracts() !void {
    inline for (.{ canvas.ColorScheme.light, canvas.ColorScheme.dark }) |scheme| {
        inline for (.{ canvas.ColorContrast.standard, canvas.ColorContrast.high }) |contrast| {
            const base = canvas.DesignTokens.theme(.{ .pack = .geist, .color_scheme = scheme, .contrast = contrast, .reduce_motion = true });
            const styled = refineTheme(base, contrast == .high);
            try std.testing.expectEqualDeep(base.colors, styled.colors);
            try std.testing.expectEqualDeep(base.motion, styled.motion);
            try std.testing.expectEqualDeep(base.stroke, styled.stroke);
            if (contrast == .high) try std.testing.expectEqualDeep(base.controls, styled.controls);
        }
    }
}
