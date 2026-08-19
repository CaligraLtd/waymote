//! Keyboard injection through `/dev/uinput` rather than Wayland.
//!
//! A `zwp_virtual_keyboard_v1` enters the compositor's seat directly, above
//! evdev, so an evdev remapper such as keyd never sees those keys and none of
//! its layers apply. Writing the same evdev codes to a uinput device puts them
//! below the remapper instead, and the compositor receives whatever the
//! remapper emits.

const UinputKeyboard = @This();

const std = @import("std");
const linux = std.os.linux;

const log = std.log.scoped(.uinput);

const device_path = "/dev/uinput";
const device_name = "waymote virtual keyboard";
// keyd claims 0x0FAC for the devices it creates itself and skips them to avoid
// feeding its own output back in. Any other vendor is treated as real hardware.
const vendor_id = 0x1D6B;
const product_id = 0x0001;
const bus_virtual = 0x06;
const max_key_code = 248;

const ev_syn = 0x00;
const ev_key = 0x01;
const syn_report = 0x00;

const ui_dev_create = 0x5501;
const ui_dev_destroy = 0x5502;
const ui_dev_setup = 0x405C5503;
const ui_set_evbit = 0x40045564;
const ui_set_keybit = 0x40045565;

const InputId = extern struct {
    bustype: u16,
    vendor: u16,
    product: u16,
    version: u16,
};

const Setup = extern struct {
    id: InputId,
    name: [80]u8,
    ff_effects_max: u32,
};

const Event = extern struct {
    seconds: i64,
    microseconds: i64,
    type: u16,
    code: u16,
    value: i32,
};

file: std.Io.File,

pub fn open(io: std.Io) !UinputKeyboard {
    const file = std.Io.Dir.openFileAbsolute(io, device_path, .{ .mode = .write_only }) catch |err| {
        log.err("could not open {s}: {t}", .{ device_path, err });
        return err;
    };
    errdefer file.close(io);

    try ioctl(file.handle, ui_set_evbit, ev_key);
    try ioctl(file.handle, ui_set_evbit, ev_syn);
    var code: u32 = 1;
    while (code < max_key_code) : (code += 1) try ioctl(file.handle, ui_set_keybit, code);

    var setup: Setup = .{
        .id = .{
            .bustype = bus_virtual,
            .vendor = vendor_id,
            .product = product_id,
            .version = 1,
        },
        .name = @splat(0),
        .ff_effects_max = 0,
    };
    @memcpy(setup.name[0..device_name.len], device_name);
    try ioctl(file.handle, ui_dev_setup, @intFromPtr(&setup));
    try ioctl(file.handle, ui_dev_create, 0);
    return .{ .file = file };
}

pub fn deinit(self: *UinputKeyboard, io: std.Io) void {
    ioctl(self.file.handle, ui_dev_destroy, 0) catch {};
    self.file.close(io);
}

pub fn key(self: *UinputKeyboard, io: std.Io, code: u32, value: i32) void {
    self.write(io, ev_key, @intCast(code), value);
    self.write(io, ev_syn, syn_report, 0);
}

fn write(self: *UinputKeyboard, io: std.Io, kind: u16, code: u16, value: i32) void {
    const event: Event = .{
        .seconds = 0,
        .microseconds = 0,
        .type = kind,
        .code = code,
        .value = value,
    };
    self.file.writeStreamingAll(io, std.mem.asBytes(&event)) catch |err| {
        log.warn("uinput write failed: {t}", .{err});
    };
}

fn ioctl(handle: std.posix.fd_t, request: u32, argument: usize) !void {
    const result = linux.ioctl(handle, request, argument);
    return switch (linux.errno(result)) {
        .SUCCESS => {},
        .ACCES, .PERM => error.AccessDenied,
        .NODEV, .NOENT => error.NoDevice,
        else => error.IoctlFailed,
    };
}
