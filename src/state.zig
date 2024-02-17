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

pub const DepartureScreenState = struct {
    station_id: std.ArrayListUnmanaged(u8),
    platform: std.ArrayListUnmanaged(u8),
    departure_date: std.time.Instant,
    loading: bool = false,
};

allocator: std.mem.Allocator,
close_app: bool = false,
db_font: ?rl.Font = null,
screen: Screen = .home,
home_screen_state: HomeScreenState,
departure_screen_state: DepartureScreenState,
