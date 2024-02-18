pub const c_api = @cImport({
    @cInclude("curl/curl.h");
});

pub const Option = enum(c_api.CURLoption) {
    write_data = c_api.CURLOPT_WRITEDATA,
    url = c_api.CURLOPT_URL,
    port = c_api.CURLOPT_PORT,
    proxy = c_api.CURLOPT_PROXY,
    userpwd = c_api.CURLOPT_USERPWD,
    proxy_userpwd = c_api.CURLOPT_PROXYUSERPWD,
    range = c_api.CURLOPT_RANGE,
    read_data = c_api.CURLOPT_READDATA,
    error_buffer = c_api.CURLOPT_ERRORBUFFER,
    write_function = c_api.CURLOPT_WRITEFUNCTION,
    read_function = c_api.CURLOPT_READFUNCTION,
    timeout = c_api.CURLOPT_TIMEOUT,
    in_file_size = c_api.CURLOPT_INFILESIZE,
    post_fields = c_api.CURLOPT_POSTFIELDS,
    referer = c_api.CURLOPT_REFERER,
    ftp_port = c_api.CURLOPT_FTPPORT,
    user_agent = c_api.CURLOPT_USERAGENT,
    low_speed_limit = c_api.CURLOPT_LOW_SPEED_LIMIT,
    low_speed_time = c_api.CURLOPT_LOW_SPEED_TIME,
    resume_from = c_api.CURLOPT_RESUME_FROM,
    cookie = c_api.CURLOPT_COOKIE,
    http_header = c_api.CURLOPT_HTTPHEADER,
    // ...
};

handle: *c_api.CURL,

pub fn init() ?@This() {
    if (c_api.curl_easy_init()) |handle| {
        return .{
            .handle = handle,
        };
    } else {
        return null;
    }
}

pub fn deinit(self: *@This()) void {
    c_api.curl_easy_cleanup(self.handle);
}

pub fn reset(self: *@This()) void {
    c_api.curl_easy_reset(self.handle);
}

pub fn perform(self: *@This()) c_api.CURLcode {
    return c_api.curl_easy_perform(self.handle);
}

pub fn setopt_raw(
    self: *@This(),
    option: c_api.CURLoption,
    args: anytype,
) c_api.CURLcode {
    return @call(
        .auto,
        c_api.curl_easy_setopt,
        .{ self.handle, option } ++ args,
    );
}

pub fn setopt(
    self: *@This(),
    option: Option,
    arg: anytype,
) c_api.CURLcode {
    return self.setopt_raw(@intFromEnum(option), .{ arg });
}

pub const Utils = struct {
	const std = @import("std");

	pub fn array_list_append(ptr: [*]u8, size: usize, nmemb: usize, userdata: *std.ArrayList(u8)) callconv(.C) usize {
	    _ = size;
	    userdata.appendSlice(ptr[0..nmemb]) catch return 0;
	    return nmemb;
	}
};
