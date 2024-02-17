const std = @import("std");
const raylib = @import("raylib.zig");
const rl = raylib.rl;

pub const Screen = enum {
    home,
    departure,
};

pub const HSSuggestion = struct {
    id: [:0]u8,
    name: [:0]u8,
};

pub const HomeScreenState = struct {
    station_name: std.ArrayListUnmanaged(u8),
    fetch_thread: ?std.Thread = null,
    suggestions: []HSSuggestion = &.{},
    selection_idx: i8 = 0,
};

pub const RenderStyle = enum(u8) {
    db1 = 1,
    ns = 3,
};

pub const DepartureScreenState = struct {
    station_id: std.ArrayListUnmanaged(u8),
    platform: std.ArrayListUnmanaged(u8),
    departure_date: std.time.Instant,
    fetch_thread: ?std.Thread = null,
    last_refresh_time: std.time.Instant = std.mem.zeroInit(std.time.Instant, .{}),
    fetch_result: ?std.json.Parsed(std.json.Value) = null,
    should_refresh: bool = false,
    max_next_trains: c_int = 5,
    include_tram: bool = false,
    render_style: RenderStyle = .db1,
};

allocator: std.mem.Allocator,
close_app: bool = false,
font: rl.Font,
screen: Screen = .home,
home_screen_state: HomeScreenState,
departure_screen_state: DepartureScreenState,
