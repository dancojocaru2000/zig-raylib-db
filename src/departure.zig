const raylib = @import("raylib.zig");
const rl = raylib.rl;
const AppState = @import("state.zig");

pub fn render(state: *AppState) !void {
    while (raylib.GetKeyPressed()) |key| {
        switch (key) {
            rl.KEY_LEFT => {
                state.screen = .home;
            },
            else => {},
        }
    }

    rl.BeginDrawing();
    defer rl.EndDrawing();

    rl.ClearBackground(raylib.ColorInt(0x18226f));
    rl.DrawText(state.departure_screen_state.station_id.items.ptr, 16, 16, 32, rl.WHITE);

    state.close_app = rl.WindowShouldClose();
}
