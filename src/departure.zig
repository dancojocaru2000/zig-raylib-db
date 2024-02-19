const std = @import("std");
const raylib = @import("raylib.zig");
const rl = raylib.rl;
const AppState = @import("state.zig");
const Curl = @import("curl.zig");
const C = @cImport({
    @cDefine("_XOPEN_SOURE", "");
    @cInclude("time.h");
});

fn getHourMin(str: [:0]const u8) struct { hour: u8, minute: u8 } {
    var tm: C.tm = undefined;
    _ = C.strptime(str, "%FT%T%z", &tm);
    return .{
        .hour = @intCast(tm.tm_hour),
        .minute = @intCast(tm.tm_min),
    };
}

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
        var fetch_anyway = state.departure_screen_state.should_refresh;
        if (state.departure_screen_state.last_refresh_time + 30000 < std.time.milliTimestamp()) {
            fetch_anyway = true;
        }
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
        _ = curl.setopt(.url, url.ptr);

        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();
        _ = curl.setopt(.write_function, Curl.Utils.array_list_append);
        _ = curl.setopt(.write_data, &result);

        const code = curl.perform();
        std.debug.print("[departure/fetchThread] cURL Code: {}\n", .{code});
        if (code != 0) continue;

        std.debug.print("[departure/fetchThread] Fetched data: <redacted>(len: {})\n", .{result.items.len});
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.items, .{}) catch |err| {
            std.debug.print("[departure/fetchThread] JSON parse error: {}\n", .{err});
            continue;
        };
        state.departure_screen_state.mutex.lock();
        defer state.departure_screen_state.mutex.unlock();
        if (state.departure_screen_state.fetch_result) |old_result| {
            old_result.deinit();
        }
        state.departure_screen_state.fetch_result = parsed;
        state.departure_screen_state.should_refresh = false;
        state.departure_screen_state.last_refresh_time = std.time.milliTimestamp();
    }
    if (state.departure_screen_state.fetch_result) |old_result| {
        old_result.deinit();
        state.departure_screen_state.fetch_result = null;
    }
}

fn draw_db1(state: *AppState) !void {
    const allocator = state.allocator;
    const ds = &state.departure_screen_state;
    const font = state.db_font orelse state.font;

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
                    raylib.DrawRightAlignedTextEx(font, station_name, @floatFromInt(rl.GetScreenWidth() - 4), 4, 14, 0.8, rl.WHITE);
                }

                var with_santinel: [200]u8 = .{0} ** 200;
                const time_struct = switch (first.get("plannedWhen").?) {
                    .string => |when| sblk: {
                        std.mem.copyForwards(u8, &with_santinel, when);
                        const time = getHourMin(with_santinel[0..(when.len) :0]);
                        break :sblk time;
                    },
                    else => unreachable,
                };
                var with_santinel_rt: [200]u8 = .{0} ** 200;
                const realtime_struct = switch (first.get("when").?) {
                    .string => |when| sblk: {
                        std.mem.copyForwards(u8, &with_santinel_rt, when);
                        const time = getHourMin(with_santinel_rt[0..(when.len) :0]);
                        if (std.meta.eql(time, time_struct)) {
                            break :sblk null;
                        }
                        break :sblk time;
                    },
                    else => null,
                };

                const line = try std.fmt.allocPrintZ(allocator, "{s}", .{first.get("line").?.object.get("name").?.string});
                defer allocator.free(line);
                const time = try std.fmt.allocPrintZ(allocator, "{d:0>2}:{d:0>2}", .{ time_struct.hour, time_struct.minute });
                defer allocator.free(time);
                const real_time = if (realtime_struct) |rts| try std.fmt.allocPrintZ(allocator, "{d:0>2}:{d:0>2}", .{ rts.hour, rts.minute }) else null;
                defer if (real_time) |rt| allocator.free(rt);
                const destination = try std.fmt.allocPrintZ(allocator, "{s}", .{first.get("direction").?.string});
                defer allocator.free(destination);
                var next_y = y;
                next_y += @intFromFloat(raylib.DrawAndMeasureTextEx(font, line, 16, @floatFromInt(y), 32, 1, rl.WHITE).y);
                next_y += 8;
                if (ds.platform.items.len == 0) blk: {
                    if (first.get("platform")) |platform_raw| {
                        switch (platform_raw) {
                            .string => |p| {
                                const platform = std.fmt.allocPrintZ(allocator, "{s}", .{p}) catch break :blk;
                                defer allocator.free(platform);

                                const platform_width: c_int = @intFromFloat(rl.MeasureTextEx(font, platform.ptr, 40, 1).x);

                                // Check if platform is different
                                const is_changed = if (first.get("plannedPlatform")) |pp| ifblk: {
                                    break :ifblk switch (pp) {
                                        .string => |pp_str| !std.mem.eql(u8, pp_str, p),
                                        else => true,
                                    };
                                } else true;

                                if (is_changed) {
                                    rl.DrawRectangle(rl.GetScreenWidth() - platform_width - 16 - 8, y, platform_width + 16, 40, rl.WHITE);
                                }
                                raylib.DrawRightAlignedTextEx(font, platform, @floatFromInt(rl.GetScreenWidth() - 16), @floatFromInt(y), 40, 1, if (is_changed) db_blue else rl.WHITE);
                            },
                            else => {},
                        }
                    }
                }
                y = next_y;

                const time_measure = raylib.DrawAndMeasureTextEx(
                    font,
                    time,
                    16,
                    @floatFromInt(y),
                    48,
                    1,
                    rl.WHITE,
                );
                next_y += @intFromFloat(time_measure.y);
                next_y += 8;
                if (real_time) |rt| {
                    rl.DrawRectangle(
                        16 + 16 + @as(c_int, @intFromFloat(time_measure.x)) + 8,
                        y,
                        @intFromFloat(time_measure.x + 16),
                        @intFromFloat(time_measure.y),
                        rl.WHITE,
                    );
                    raylib.DrawTextEx(
                        font,
                        rt,
                        16 * 3 + time_measure.x,
                        @floatFromInt(y),
                        48,
                        1,
                        db_blue,
                    );
                }
                y = next_y;

                y += @intFromFloat(raylib.DrawAndMeasureTextEx(
                    font,
                    destination,
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
                    font,
                    if (max_trains == 1) "Next train: " else "Next trains: ",
                    @floatFromInt(x),
                    @floatFromInt(y),
                    @floatFromInt(font_size),
                    1,
                    db_blue,
                ).x));
                x += label_measurement_width;

                // Compute line name width
                var time_width: c_int = 0;
                var line_name_width: c_int = 0;
                var platform_width: c_int = 0;
                for (not_cancelled.items, 0..) |dep_raw, idx| {
                    if (idx == 0) continue;
                    if (idx > max_trains) break;
                    const second = dep_raw.object;
                    const time = try std.fmt.allocPrintZ(allocator, "00:00  ", .{});
                    defer allocator.free(time);
                    time_width = @max(
                        time_width,
                        @as(c_int, @intFromFloat(rl.MeasureTextEx(font, time.ptr, @floatFromInt(font_size), 1).x)),
                    );
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
                        @as(c_int, @intFromFloat(rl.MeasureTextEx(font, next_train_line.ptr, @floatFromInt(font_size), 1).x)),
                    );

                    if (second.get("platform")) |platform_raw| {
                        switch (platform_raw) {
                            .string => |p| {
                                const platform = std.fmt.allocPrintZ(allocator, "{s}", .{p}) catch continue;
                                defer allocator.free(platform);
                                platform_width = @max(
                                    platform_width,
                                    @as(c_int, @intFromFloat(rl.MeasureTextEx(font, platform.ptr, @floatFromInt(font_size), 1).x)),
                                );
                            },
                            else => {},
                        }
                    }
                }
                const line_x = x + time_width;
                const destionation_x = line_x + line_name_width;

                for (not_cancelled.items, 0..) |dep_raw, idx| {
                    if (idx == 0) continue;
                    if (idx > max_trains) break;
                    const second = dep_raw.object;

                    var with_santinel: [200]u8 = .{0} ** 200;

                    const schedule_time = switch (second.get("plannedWhen").?) {
                        .string => |when| sblk: {
                            std.mem.copyForwards(u8, &with_santinel, when);
                            const time = getHourMin(with_santinel[0..(when.len) :0]);
                            break :sblk time;
                        },
                        else => unreachable,
                    };
                    const time = switch (second.get("when").?) {
                        .string => |when| sblk: {
                            std.mem.copyForwards(u8, &with_santinel, when);
                            const time = getHourMin(with_santinel[0..(when.len) :0]);
                            break :sblk time;
                        },
                        else => sblk: {
                            const plannedWhen = second.get("plannedWhen").?.string;
                            std.mem.copyForwards(u8, &with_santinel, plannedWhen);
                            const time = getHourMin(with_santinel[0..(plannedWhen.len) :0]);
                            break :sblk time;
                        },
                    };

                    const time_str = try std.fmt.allocPrintZ(
                        allocator,
                        "{:0>2}:{:0>2}  ",
                        .{
                            time.hour,
                            time.minute,
                        },
                    );
                    defer allocator.free(time_str);
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
                    rl.DrawTextEx(font, time_str.ptr, .{ .x = @floatFromInt(x), .y = @floatFromInt(y) }, font_size, 1, if (std.meta.eql(schedule_time, time)) db_blue else rl.RED);
                    rl.DrawTextEx(font, next_train_line.ptr, .{ .x = @floatFromInt(line_x), .y = @floatFromInt(y) }, font_size, 1, db_blue);
                    rl.DrawTextEx(font, next_train_direction.ptr, .{ .x = @floatFromInt(destionation_x), .y = @floatFromInt(y) }, font_size, 1, db_blue);
                    if (ds.platform.items.len == 0) blk: {
                        if (second.get("platform")) |platform_raw| {
                            switch (platform_raw) {
                                .string => |p| {
                                    // Check if platform is different
                                    const is_changed = if (second.get("plannedPlatform")) |pp| ifblk: {
                                        break :ifblk switch (pp) {
                                            .string => |pp_str| !std.mem.eql(u8, pp_str, p),
                                            else => true,
                                        };
                                    } else true;

                                    if (is_changed) {
                                        rl.DrawRectangle(rl.GetScreenWidth() - platform_width - 16 - 8, y, platform_width + 16, font_size, db_blue);
                                    }
                                    const platform = std.fmt.allocPrintZ(allocator, "{s}", .{p}) catch break :blk;
                                    defer allocator.free(platform);
                                    raylib.DrawRightAlignedTextEx(font, platform, @floatFromInt(rl.GetScreenWidth() - 16), @floatFromInt(y), @floatFromInt(font_size), 1, if (is_changed) rl.WHITE else db_blue);
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
}

fn draw_ns(state: *AppState) !void {
    const allocator = state.allocator;
    const ds = &state.departure_screen_state;
    const font = state.ns_font orelse state.font;
    _ = .{ allocator, ds };

    const ms = std.time.milliTimestamp();
    const language = @rem(@divTrunc(ms, 5000), 2);

    const ns_bg1 = raylib.ColorInt(0xE6e6e6);
    const ns_bg2 = raylib.ColorInt(0xbdd1d9);
    const ns_fg1 = raylib.ColorInt(0x1a4379);
    const ns_fg2 = raylib.ColorInt(0x6795af);
    const ns_fg3 = raylib.ColorInt(0xab5161);
    const header_fs: f32 = 16;
    const station_fs: f32 = 28;
    const cancel_fs: f32 = 24;
    const platform_fs: f32 = 28;
    rl.ClearBackground(ns_bg1);

    const col1w = rl.MeasureTextEx(font, "00:00", station_fs, 1).x;

    const header_height = rl.MeasureTextEx(font, "Vertrek", header_fs, 1).y;
    rl.DrawRectangle(0, 0, rl.GetScreenWidth(), 4 + @as(c_int, @intFromFloat(header_height)) + 4, ns_bg2);
    raylib.DrawTextEx(font, if (language == 0) "Vertrek" else "Depart", 8, 4, header_fs, 1, ns_fg1);
    raylib.DrawTextEx(font, if (language == 0) "Naar/Opmerking" else "To/Via", 8 + col1w + 8, 4, header_fs, 1, ns_fg1);
    raylib.DrawTextEx(font, if (language == 0) "Spoor" else "Platform", @floatFromInt(rl.GetScreenWidth() - 200), 4, header_fs, 1, ns_fg1);

    var y = header_height + 8 + 2;

    if (ds.fetch_result) |data| {
        if (data.value.object.get("departures")) |departures_raw| {
            const departures = departures_raw.array.items;
            for (departures, 0..) |d, idx| {
                const line1h = rl.MeasureTextEx(font, "00:00", station_fs, 1).y;
                const line2h = rl.MeasureTextEx(font, "Cancelled", cancel_fs, 1).y;
                const total_height = line1h + 4 + line2h + 2;
                if (@mod(idx, 2) == 1) {
                    // Alternate background
                    rl.DrawRectangle(0, @intFromFloat(y), rl.GetScreenWidth(), @intFromFloat(total_height), ns_bg2);
                }

                const train = d.object;
                const cancelled = blk: {
                    if (train.get("cancelled")) |cancelled| {
                        switch (cancelled) {
                            .bool => |b| {
                                break :blk b;
                            },
                            else => {},
                        }
                    }
                    break :blk false;
                };

                blk: {
                    var with_santinel: [200]u8 = .{0} ** 200;

                    const time = switch (train.get("when").?) {
                        .string => |when| sblk: {
                            std.mem.copyForwards(u8, &with_santinel, when);
                            const time = getHourMin(with_santinel[0..(when.len) :0]);
                            break :sblk time;
                        },
                        else => sblk: {
                            const plannedWhen = train.get("plannedWhen").?.string;
                            std.mem.copyForwards(u8, &with_santinel, plannedWhen);
                            const time = getHourMin(with_santinel[0..(plannedWhen.len) :0]);
                            break :sblk time;
                        },
                    };
                    const time_str = std.fmt.allocPrintZ(allocator, "{:0>2}:{:0>2}", .{ time.hour, time.minute }) catch break :blk;
                    defer allocator.free(time_str);
                    raylib.DrawTextEx(font, time_str, 8, y, station_fs, 1, if (cancelled) ns_fg2 else ns_fg1);
                }
                const direction = try std.fmt.allocPrintZ(
                    allocator,
                    "{s}",
                    .{
                        train.get("direction").?.string,
                    },
                );
                defer allocator.free(direction);
                raylib.DrawTextEx(font, direction, 8 + col1w + 8, y, station_fs, 1, if (cancelled) ns_fg2 else ns_fg1);

                // Draw platform square
                const square_side = total_height - 4;
                const sw = rl.GetScreenWidth();
                if (train.get("platform")) |platform_raw| {
                    switch (platform_raw) {
                        .string => |p| {
                            const platform = std.fmt.allocPrintZ(allocator, "{s}", .{p}) catch continue;
                            defer allocator.free(platform);

                            rl.DrawRectangle(sw - 200, @intFromFloat(y + 2), 12, 12, if (cancelled) ns_fg2 else ns_fg1);
                            rl.DrawLine(sw - 200, @intFromFloat(y + 2), sw - 200, @intFromFloat(y + 2 + square_side), if (cancelled) ns_fg2 else ns_fg1);
                            rl.DrawLine(sw - 200 + @as(c_int, @intFromFloat(square_side)), @intFromFloat(y + 2), sw - 200 + @as(c_int, @intFromFloat(square_side)), @intFromFloat(y + 2 + square_side), if (cancelled) ns_fg2 else ns_fg1);
                            rl.DrawLine(sw - 200, @intFromFloat(y + 2), sw - 200 + @as(c_int, @intFromFloat(square_side)), @intFromFloat(y + 2), if (cancelled) ns_fg2 else ns_fg1);
                            rl.DrawLine(sw - 200, @intFromFloat(y + 2 + square_side), sw - 200 + @as(c_int, @intFromFloat(square_side)), @intFromFloat(y + 2 + square_side), if (cancelled) ns_fg2 else ns_fg1);

                            const text_size = rl.MeasureTextEx(font, platform.ptr, platform_fs, 1);
                            raylib.DrawTextEx(
                                font,
                                if (cancelled) "-" else platform,
                                @as(f32, @floatFromInt(sw - 200)) + @divTrunc(square_side, 2) - (text_size.x / 2),
                                y + 2 + @divTrunc(square_side, 2) - (text_size.y / 2),
                                platform_fs,
                                1,
                                if (cancelled) ns_fg2 else ns_fg1,
                            );
                        },
                        else => {
                            if (cancelled) {
                                rl.DrawRectangle(sw - 200, @intFromFloat(y + 2), 12, 12, if (cancelled) ns_fg2 else ns_fg1);
                                rl.DrawLine(sw - 200, @intFromFloat(y + 2), sw - 200, @intFromFloat(y + 2 + square_side), if (cancelled) ns_fg2 else ns_fg1);
                                rl.DrawLine(sw - 200 + @as(c_int, @intFromFloat(square_side)), @intFromFloat(y + 2), sw - 200 + @as(c_int, @intFromFloat(square_side)), @intFromFloat(y + 2 + square_side), if (cancelled) ns_fg2 else ns_fg1);
                                rl.DrawLine(sw - 200, @intFromFloat(y + 2), sw - 200 + @as(c_int, @intFromFloat(square_side)), @intFromFloat(y + 2), if (cancelled) ns_fg2 else ns_fg1);
                                rl.DrawLine(sw - 200, @intFromFloat(y + 2 + square_side), sw - 200 + @as(c_int, @intFromFloat(square_side)), @intFromFloat(y + 2 + square_side), if (cancelled) ns_fg2 else ns_fg1);

                                const text_size = rl.MeasureTextEx(font, "-", platform_fs, 1);
                                raylib.DrawTextEx(
                                    font,
                                    "-",
                                    @as(f32, @floatFromInt(sw - 200)) + @divTrunc(square_side, 2) - (text_size.x / 2),
                                    y + 2 + @divTrunc(square_side, 2) - (text_size.y / 2),
                                    platform_fs,
                                    1,
                                    if (cancelled) ns_fg2 else ns_fg1,
                                );
                            }
                        },
                    }
                }

                y += line1h + 4;
                const cancelled_h = raylib.DrawAndMeasureTextEx(font, if (cancelled) (if (language == 0) "Rijdt niet" else "Cancelled") else " ", 8 + col1w + 8, y, cancel_fs, 1, ns_fg3).y;
                y += cancelled_h + 4;
            }
        }
    }
}

pub fn render(state: *AppState) !void {
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
            rl.KEY_EQUAL, rl.KEY_KP_ADD => {
                ds.mutex.lock();
                defer ds.mutex.unlock();
                ds.max_next_trains = @min(ds.max_next_trains + 1, if (ds.fetch_result) |fr| @as(c_int, @intCast(fr.value.object.get("departures").?.array.items.len)) else 5);
            },
            rl.KEY_T => {
                ds.include_tram = !ds.include_tram;
            },
            rl.KEY_ONE => {
                ds.render_style = .db1;
            },
            rl.KEY_THREE => {
                ds.render_style = .ns;
            },
            else => {},
        }
    }

    rl.BeginDrawing();
    defer rl.EndDrawing();

    {
        ds.mutex.lock();
        defer ds.mutex.unlock();
        switch (ds.render_style) {
            .db1 => try draw_db1(state),
            .ns => try draw_ns(state),
        }
    }

    state.close_app = rl.WindowShouldClose();
}
