const std = @import("std");
const raylib = @import("raylib.zig");
const rl = raylib.rl;
const state_mod = @import("state.zig");
const curl_mod = @import("curl.zig");

fn curlWriteHandler(ptr: [*]u8, size: usize, nmemb: usize, userdata: *std.ArrayList(u8)) callconv(.C) usize {
    _ = size;
    userdata.appendSlice(ptr[0..nmemb]) catch return 0;
    return nmemb;
}

fn fetchThread(state: *state_mod.AppState) !void {
    std.debug.print("Started fetchThread\n", .{});
    defer std.debug.print("Ended fetchThread\n", .{});
    defer state.home_screen_state.fetch_thread = null;
    const allocator = state.allocator;
    var station_name_buf = std.BoundedArray(u8, 200){};
    var curl = curl_mod.init() orelse return;
    defer curl.deinit();
    const locations_base = "https://v6.db.transport.rest/locations";
    var locations_uri = std.Uri.parse(locations_base) catch unreachable;

    while (state.home_screen_state.fetch_thread != null) {
        if (std.mem.eql(u8, station_name_buf.slice(), state.home_screen_state.station_name.items)) {
            std.time.sleep(100 * 1000);
            continue;
        }

        station_name_buf.resize(state.home_screen_state.station_name.items.len) catch continue;
        std.mem.copyForwards(u8, station_name_buf.slice(), state.home_screen_state.station_name.items);

        std.debug.print("[fetchThread] Detected update: {s}\n", .{station_name_buf.slice()});

        curl.reset();

        const query = try std.fmt.allocPrint(allocator, "query={s}&results=10&addresses=false&poi=false&pretty=false", .{station_name_buf.slice()});
        defer allocator.free(query);
        locations_uri.query = query;
        defer locations_uri.query = null;
        std.debug.print("[fetchThread] Making request to: {}\n", .{locations_uri});

        const url = try std.fmt.allocPrintZ(allocator, "{}", .{locations_uri});
        defer allocator.free(url);
        _ = curl.setopt(.url, .{url.ptr});

        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();
        _ = curl.setopt(.write_function, .{curlWriteHandler});
        _ = curl.setopt(.write_data, .{&result});

        const code = curl.perform();
        std.debug.print("[fetchThread] cURL Code: {}\n", .{code});
        if (code != 0) continue;

        std.debug.print("[fetchThread] Fetched data: <redacted>(len: {})\n", .{result.items.len});
        const parsed = std.json.parseFromSlice([]const std.json.Value, allocator, result.items, .{}) catch |err| {
            std.debug.print("[fetchThread] JSON parse error: {}\n", .{err});
            continue;
        };
        defer parsed.deinit();

        var results = std.ArrayList(state_mod.HSSuggestion).init(allocator);
        for (parsed.value) |station| {
            if (station.object.get("name")) |nameValue| {
                const name = nameValue.string;
                if (station.object.get("id")) |idValue| {
                    const id = idValue.string;

                    results.append(.{
                        .id = std.fmt.allocPrintZ(allocator, "{s}", .{id}) catch continue,
                        .name = std.fmt.allocPrintZ(allocator, "{s}", .{name}) catch continue,
                    }) catch continue;
                }
            }
        }
        if (state.home_screen_state.suggestions.len > 0) {
            for (state.home_screen_state.suggestions) |suggestion| {
                allocator.free(suggestion.id);
                allocator.free(suggestion.name);
            }
            allocator.free(state.home_screen_state.suggestions);
        }
        state.home_screen_state.suggestions = results.toOwnedSlice() catch continue;
    }
}

pub fn render(state: *state_mod.AppState) !void {
    var hs = &state.home_screen_state;

    if (hs.fetch_thread == null) {
        hs.fetch_thread = std.Thread.spawn(.{}, fetchThread, .{state}) catch null;
    }
    if (hs.suggestions.len > 0 and hs.selection_idx > hs.suggestions.len - 1) {
        hs.selection_idx = @intCast(hs.suggestions.len - 1);
    }

    while (raylib.GetCharPressed()) |char| {
        hs.station_name.appendAssumeCapacity(@intCast(char));
    }
    while (raylib.GetKeyPressed()) |key| {
        switch (key) {
            rl.KEY_BACKSPACE => {
                if (hs.station_name.items.len > 0) {
                    hs.station_name.items[hs.station_name.items.len - 1] = 0;
                    _ = hs.station_name.pop();
                }
            },
            rl.KEY_UP => {
                hs.selection_idx -= 1;
                if (hs.suggestions.len > 0 and hs.selection_idx < 0) {
                    hs.selection_idx = @intCast(hs.suggestions.len - 1);
                }
            },
            rl.KEY_DOWN => {
                hs.selection_idx += 1;
                if (hs.suggestions.len > 0 and hs.selection_idx > hs.suggestions.len - 1) {
                    hs.selection_idx = 0;
                }
            },
            rl.KEY_ENTER => {
                if (hs.suggestions.len > 0 and hs.selection_idx < hs.suggestions.len) {
                    state.departure_screen_state.station_id.clearRetainingCapacity();
                    state.departure_screen_state.station_id.appendSliceAssumeCapacity(hs.suggestions[@intCast(hs.selection_idx)].id);
                    state.screen = .departure;
                    hs.fetch_thread = null;
                }
            },
            else => {},
        }
    }

    rl.BeginDrawing();
    defer rl.EndDrawing();

    var x: c_int = 16;
    var y: c_int = 16;

    const title_size: c_int = 32;
    const body_size: c_int = 28;

    rl.ClearBackground(rl.BLACK);
    x += raylib.DrawAndMeasureText("Station: ", x, y, title_size, rl.WHITE).width + 8;
    rl.DrawLine(x, y + title_size + 2, rl.GetScreenWidth() - 16, y + title_size + 2, rl.WHITE);
    if (state.db_font) |db_font| {
        rl.DrawTextEx(db_font, hs.station_name.items.ptr, rl.Vector2{ .x = @floatFromInt(x), .y = @floatFromInt(y) }, title_size, 0.9, rl.WHITE);
    } else {
        rl.DrawText(hs.station_name.items.ptr, x, y, title_size, rl.WHITE);
    }

    y += title_size + 2 + 16;

    for (hs.suggestions, 0..) |suggestion, idx| {
        var color = if (hs.selection_idx == idx) rl.YELLOW else rl.WHITE;

        // Draw arrow for selection
        if (hs.selection_idx == idx) {
            const arrow_margin: c_int = 16;
            rl.DrawLine(x - 10 - arrow_margin, y + body_size / 4, x - arrow_margin, y + body_size / 2, color);
            rl.DrawLine(x - arrow_margin, y + body_size / 2, x - 10 - arrow_margin, y + body_size * 3 / 4, color);
        }

        // Check if mouse is hovering
        if (rl.CheckCollisionPointRec(rl.GetMousePosition(), rl.Rectangle{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .width = @floatFromInt(rl.GetScreenWidth() - 16 - x),
            .height = @floatFromInt(body_size),
        })) {
            color = rl.BLUE;

            if (rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) {
                // Select
                state.departure_screen_state.station_id.clearRetainingCapacity();
                state.departure_screen_state.station_id.appendSliceAssumeCapacity(suggestion.id);
                state.screen = .departure;
                hs.fetch_thread = null;
                return;
            }
        }

        if (state.db_font) |db_font| {
            rl.DrawTextEx(db_font, suggestion.name.ptr, rl.Vector2{ .x = @floatFromInt(x), .y = @floatFromInt(y) }, body_size, 0.9, color);
        } else {
            rl.DrawText(suggestion.name.ptr, x, y, body_size, color);
        }

        y += body_size + 2;
    }

    state.close_app = rl.WindowShouldClose();
}
