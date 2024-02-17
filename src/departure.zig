const std = @import("std");
const raylib = @import("raylib.zig");
const rl = raylib.rl;
const AppState = @import("state.zig");
const Curl = @import("curl.zig");

fn fetchThread(state: *AppState) !void {
    std.debug.print("[departure/fetchThread] Started\n", .{});
    defer std.debug.print("[departure/fetchThread] Ended\n", .{});
    defer state.departure_screen_state.fetch_thread = null;
    const allocator = state.allocator;
    var station_id_buf = std.BoundedArray(u8, 10){};
    var include_tram = false;
    var curl = Curl.init() orelse return;
    defer curl.deinit();

    while (state.departure_screen_state.fetch_thread != null) {
        const fetch_anyway = state.departure_screen_state.should_refresh;
        if (!fetch_anyway and std.mem.eql(u8, station_id_buf.slice(), state.departure_screen_state.station_id.items) and include_tram == state.departure_screen_state.include_tram) {
            std.time.sleep(100 * 1000);
            continue;
        }

        station_id_buf.resize(state.departure_screen_state.station_id.items.len) catch continue;
        std.mem.copyForwards(u8, station_id_buf.slice(), state.departure_screen_state.station_id.items);
        include_tram = state.departure_screen_state.include_tram;
        std.debug.print("[departure/fetchThread] Detected update: {s}\n", .{station_id_buf.slice()});

        curl.reset();

        const departures_base = std.fmt.allocPrintZ(
            allocator,
            "https://v6.db.transport.rest/stops/{s}/departures",
            .{state.departure_screen_state.station_id.items},
        ) catch continue;
        defer allocator.free(departures_base);
        var departures_uri = std.Uri.parse(departures_base) catch unreachable;
        const query = std.fmt.allocPrint(allocator, "duration=300&bus=false&ferry=false&taxi=false&pretty=false{s}", .{if (include_tram) "" else "&tram=false&subway=false"}) catch continue;
        defer allocator.free(query);
        departures_uri.query = query;
        defer departures_uri.query = null;
        std.debug.print("[departure/fetchThread] Making request to: {}\n", .{departures_uri});

        const url = try std.fmt.allocPrintZ(allocator, "{}", .{departures_uri});
        defer allocator.free(url);
        _ = curl.setopt(.url, .{url.ptr});

        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();
        _ = curl.setopt(.write_function, .{Curl.Utils.array_list_append});
        _ = curl.setopt(.write_data, .{&result});

        const code = curl.perform();
        std.debug.print("[departure/fetchThread] cURL Code: {}\n", .{code});
        if (code != 0) continue;

        std.debug.print("[departure/fetchThread] Fetched data: <redacted>(len: {})\n", .{result.items.len});
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.items, .{}) catch |err| {
            std.debug.print("[departure/fetchThread] JSON parse error: {}\n", .{err});
            continue;
        };
        if (state.departure_screen_state.fetch_result) |old_result| {
            old_result.deinit();
        }
        state.departure_screen_state.fetch_result = parsed;
        state.departure_screen_state.should_refresh = false;
    }
    if (state.departure_screen_state.fetch_result) |old_result| {
        old_result.deinit();
        state.departure_screen_state.fetch_result = null;
    }
}

pub fn render(state: *AppState) !void {
    const allocator = state.allocator;
    var ds = &state.departure_screen_state;

    if (ds.fetch_thread == null) {
        ds.fetch_thread = std.Thread.spawn(.{}, fetchThread, .{state}) catch null;
    }

    while (raylib.GetKeyPressed()) |key| {
        switch (key) {
            rl.KEY_LEFT => {
                state.screen = .home;
            },
            rl.KEY_R => {
                ds.should_refresh = true;
            },
            rl.KEY_MINUS, rl.KEY_KP_SUBTRACT => {
                ds.max_next_trains = @max(1, ds.max_next_trains - 1);
            },
            rl.KEY_EQUAL, rl.KEY_KP_EQUAL => {
                ds.max_next_trains = @min(ds.max_next_trains + 1, if (ds.fetch_result) |fr| @as(c_int, @intCast(fr.value.object.get("departures").?.array.items.len)) else 5);
            },
            rl.KEY_T => {
                ds.include_tram = !ds.include_tram;
            },
            else => {},
        }
    }

    rl.BeginDrawing();
    defer rl.EndDrawing();

    const db_blue = raylib.ColorInt(0x18226f);
    rl.ClearBackground(if (ds.should_refresh) rl.ORANGE else db_blue);
    if (ds.fetch_result) |data| {
        if (data.value.object.get("departures")) |departures_raw| {
            const departures = departures_raw.array.items;
            var not_cancelled = std.ArrayList(std.json.Value).init(allocator);
            defer not_cancelled.deinit();
            for (departures) |d| {
                if (d.object.get("cancelled")) |c| {
                    switch (c) {
                        .bool => |b| {
                            if (b) {
                                continue;
                            }
                        },
                        else => {},
                    }
                }
                not_cancelled.append(d) catch continue;
            }
            if (not_cancelled.items.len > 0) {
                var y: c_int = 16;
                // Info area
                y += 32 + 16;
                const first = not_cancelled.items[0].object;

                station_name_blk: {
                    const station_name = std.fmt.allocPrintZ(allocator, "{s}", .{first.get("stop").?.object.get("name").?.string}) catch break :station_name_blk;
                    defer allocator.free(station_name);
                    rl.SetWindowTitle(station_name.ptr);
                    raylib.DrawRightAlignedText(station_name.ptr, rl.GetScreenWidth() - 4, 4, 14, rl.WHITE);
                }

                const line = try std.fmt.allocPrintZ(allocator, "{s}", .{first.get("line").?.object.get("name").?.string});
                defer allocator.free(line);
                const destination = try std.fmt.allocPrintZ(allocator, "{s}", .{first.get("direction").?.string});
                defer allocator.free(destination);
                var next_y = y;
                next_y += @intFromFloat(raylib.DrawAndMeasureTextEx(state.font, line.ptr, 16, @floatFromInt(y), 32, 1, rl.WHITE).y);
                next_y += 16;
                if (ds.platform.items.len == 0) blk: {
                    if (first.get("platform")) |platform_raw| {
                        switch (platform_raw) {
                            .string => |p| {
                                const platform = std.fmt.allocPrintZ(allocator, "{s}", .{p}) catch break :blk;
                                defer allocator.free(platform);
                                raylib.DrawRightAlignedTextEx(state.font, platform.ptr, @floatFromInt(rl.GetScreenWidth() - 16), @floatFromInt(y), 40, 1, rl.WHITE);
                            },
                            else => {},
                        }
                    }
                }
                y = next_y;
                y += @intFromFloat(raylib.DrawAndMeasureTextEx(
                    state.font,
                    destination.ptr,
                    16,
                    @floatFromInt(y),
                    56,
                    1,
                    rl.WHITE,
                ).y);

                y += 16;
            }
            if (not_cancelled.items.len > 1) {
                var max_trains: c_int = @intCast(not_cancelled.items.len - 1);
                if (max_trains > ds.max_next_trains) max_trains = ds.max_next_trains;
                const font_size: c_int = 32;
                var x: c_int = 16;
                var y = rl.GetScreenHeight() - (font_size + 8) * max_trains - 4;
                rl.DrawRectangle(0, y, rl.GetScreenWidth(), rl.GetScreenHeight(), rl.WHITE);
                y += 8;
                const label_measurement_width = @as(c_int, @intFromFloat(raylib.DrawAndMeasureTextEx(
                    state.font,
                    if (max_trains == 1) "Next train: " else "Next trains: ",
                    @floatFromInt(x),
                    @floatFromInt(y),
                    @floatFromInt(font_size),
                    1,
                    db_blue,
                ).x));
                x += label_measurement_width;

                // Compute line name width
                var line_name_width: c_int = 0;
                for (not_cancelled.items, 0..) |dep_raw, idx| {
                    if (idx == 0) continue;
                    if (idx > max_trains) break;
                    const second = dep_raw.object;
                    const next_train_line = try std.fmt.allocPrintZ(
                        allocator,
                        "{s} ",
                        .{
                            second.get("line").?.object.get("name").?.string,
                        },
                    );
                    defer allocator.free(next_train_line);
                    line_name_width = @max(
                        line_name_width,
                        @as(c_int, @intFromFloat(rl.MeasureTextEx(state.font, next_train_line.ptr, @floatFromInt(font_size), 1).x)),
                    );
                }
                const destionation_x = x + line_name_width;

                for (not_cancelled.items, 0..) |dep_raw, idx| {
                    if (idx == 0) continue;
                    if (idx > max_trains) break;
                    const second = dep_raw.object;
                    const next_train_line = try std.fmt.allocPrintZ(
                        allocator,
                        "{s} ",
                        .{
                            second.get("line").?.object.get("name").?.string,
                        },
                    );
                    defer allocator.free(next_train_line);
                    const next_train_direction = try std.fmt.allocPrintZ(
                        allocator,
                        "{s}",
                        .{
                            second.get("direction").?.string,
                        },
                    );
                    defer allocator.free(next_train_direction);
                    rl.DrawTextEx(state.font, next_train_line.ptr, .{ .x = @floatFromInt(x), .y = @floatFromInt(y) }, font_size, 1, db_blue);
                    rl.DrawTextEx(state.font, next_train_direction.ptr, .{ .x = @floatFromInt(destionation_x), .y = @floatFromInt(y) }, font_size, 1, db_blue);
                    if (ds.platform.items.len == 0) blk: {
                        if (second.get("platform")) |platform_raw| {
                            switch (platform_raw) {
                                .string => |p| {
                                    const platform = std.fmt.allocPrintZ(allocator, "{s}", .{p}) catch break :blk;
                                    defer allocator.free(platform);
                                    raylib.DrawRightAlignedTextEx(state.font, platform.ptr, @floatFromInt(rl.GetScreenWidth() - 16), @floatFromInt(y), @floatFromInt(font_size), 1, db_blue);
                                },
                                else => {},
                            }
                        }
                    }
                    y += font_size + 4;
                    rl.DrawLine(x, y, rl.GetScreenWidth() - 8, y, db_blue);
                    y += 4;
                }
            }
        }
    } else {
        rl.DrawText(state.departure_screen_state.station_id.items.ptr, 16, 16, 32, rl.WHITE);
    }

    state.close_app = rl.WindowShouldClose();
}
