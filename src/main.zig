const std = @import("std");
const raylib = @import("raylib.zig");
const rl = raylib.rl;
const home = @import("home.zig");
const departure = @import("departure.zig");
const AppState = @import("state.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    rl.SetConfigFlags(rl.FLAG_WINDOW_RESIZABLE | rl.FLAG_VSYNC_HINT);
    rl.SetTargetFPS(60);
    rl.InitWindow(800, 600, "Testing Raylib");
    defer rl.CloseWindow();

    const font = blk: {
    	var cp_cnt: c_int = 0;
     	const cp = rl.LoadCodepoints("aäbcdeèéfghijklmnoöpqrsßtuüvwxyzAÄBCDEÈÉFGHIJKLMNOÖPQRSẞTUÜVWXYZ0123456789-_,()/\\:+", &cp_cnt,);
        const maybeFont = rl.LoadFontEx("./db.ttf", 64, cp, cp_cnt);
        if (std.meta.eql(maybeFont, rl.GetFontDefault())) {
	        break :blk null;
        }
        break :blk maybeFont;
    };

    var station_name_buffer: [100]u8 = .{0} ** 100;
    var platform_buffer: [20]u8 = .{0} ** 20;
    var station_id_buffer: [10]u8 = .{0} ** 10;
    var appState = AppState{
        .allocator = allocator,
        .db_font = font,
        .home_screen_state = .{
            .station_name = std.ArrayListUnmanaged(u8).initBuffer(&station_name_buffer),
        },
        .departure_screen_state = .{
            .platform = std.ArrayListUnmanaged(u8).initBuffer(&platform_buffer),
            .station_id = std.ArrayListUnmanaged(u8).initBuffer(&station_id_buffer), // 7 digit id
            .departure_date = std.time.Instant.now() catch @panic("Idk buddy, hook a wall clock to your CPU ig"),
        },
    };
    while (!appState.close_app) {
        switch (appState.screen) {
            .home => try home.render(&appState),
            .departure => try departure.render(&appState),
        }
    }
}
