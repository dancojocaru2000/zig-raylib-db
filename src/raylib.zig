pub const rl = @cImport({
    @cInclude("raylib.h");
});

pub fn Color(r: u8, g: u8, b: u8, a: u8) rl.Color {
    return .{
        .r = r,
        .g = g,
        .b = b,
        .a = a,
    };
}
pub fn ColorInt(whole: u24) rl.Color {
    return ColorIntA(@as(u32, whole) << 8 | 0xFF);
}
pub fn ColorIntA(whole: u32) rl.Color {
    return .{
        // zig fmt: off
        .r = @truncate(whole >> 24),
        .g = @truncate(whole >> 16),
        .b = @truncate(whole >>  8),
        .a = @truncate(whole >>  0),
        // zig fmt: on
    };
}
pub fn DrawAndMeasureText(
    text: [*c]const u8,
    pos_x: c_int,
    pos_y: c_int,
    font_size: c_int,
    color: rl.Color,
) struct { width: c_int, height: c_int } {
    rl.DrawText(text, pos_x, pos_y, font_size, color);
    return .{
        .width = rl.MeasureText(text, font_size),
        .height = 10,
    };
}
pub fn DrawTextEx(
    font: rl.Font,
    text: [*c]const u8,
    pos_x: f32,
    pos_y: f32,
    font_size: f32,
    spacing: f32,
    color: rl.Color,
) void {
    rl.DrawTextEx(font, text, rl.Vector2{ .x = pos_x, .y = pos_y }, font_size, spacing, color);
}
pub fn DrawAndMeasureTextEx(
    font: rl.Font,
    text: [*c]const u8,
    pos_x: f32,
    pos_y: f32,
    font_size: f32,
    spacing: f32,
    color: rl.Color,
) rl.Vector2 {
    rl.DrawTextEx(font, text, rl.Vector2{ .x = pos_x, .y = pos_y }, font_size, spacing, color);
    return rl.MeasureTextEx(font, text, font_size, spacing);
}
pub fn DrawRightAlignedText(
    text: [*c]const u8,
    pos_x: c_int,
    pos_y: c_int,
    font_size: c_int,
    color: rl.Color,
) void {
    const width = rl.MeasureText(text, font_size);
    rl.DrawText(text, pos_x - width, pos_y, font_size, color);
}
pub fn DrawRightAlignedTextEx(
    font: rl.Font,
    text: [*c]const u8,
    pos_x: f32,
    pos_y: f32,
    font_size: f32,
    spacing: f32,
    color: rl.Color,
) void {
    const width = rl.MeasureTextEx(font, text, font_size, spacing).x;
    rl.DrawTextEx(font, text, .{ .x = pos_x - width, .y = pos_y }, font_size, spacing, color);
}
pub fn GetKeyPressed() ?c_int {
    const result = rl.GetKeyPressed();
    return if (result == 0)
        null
    else
        result;
}
pub fn GetCharPressed() ?c_int {
    const result = rl.GetCharPressed();
    return if (result == 0)
        null
    else
        result;
}
