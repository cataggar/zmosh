/// Thin wrappers around std.c functions to replace removed std.posix functions.
/// These replicate the old posix API signatures so callers need minimal changes.
const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const c = std.c;

/// Network address type replacing the removed std.net.Address.
pub const Address = extern union {
    in: c.sockaddr.in,
    in6: c.sockaddr.in6,
    any: posix.sockaddr,

    pub fn initIp4(addr: [4]u8, port: u16) Address {
        const port_be = std.mem.nativeTo(u16, port, .big);
        return .{ .in = .{
            .family = posix.AF.INET,
            .port = port_be,
            .addr = @bitCast(addr),
        } };
    }

    pub fn initIp6(addr: [16]u8, port: u16, flowinfo: u32, scope_id: u32) Address {
        const port_be = std.mem.nativeTo(u16, port, .big);
        return .{ .in6 = .{
            .family = posix.AF.INET6,
            .port = port_be,
            .flowinfo = flowinfo,
            .addr = addr,
            .scope_id = scope_id,
        } };
    }

    pub fn getPort(self: Address) u16 {
        return std.mem.toNative(u16, switch (self.any.family) {
            posix.AF.INET => self.in.port,
            posix.AF.INET6 => self.in6.port,
            else => 0,
        }, .big);
    }

    pub fn getOsSockLen(self: Address) posix.socklen_t {
        return switch (self.any.family) {
            posix.AF.INET => @sizeOf(c.sockaddr.in),
            posix.AF.INET6 => @sizeOf(c.sockaddr.in6),
            else => @sizeOf(posix.sockaddr),
        };
    }

    /// Parse a numeric IP address string (e.g. "127.0.0.1" or "::1").
    pub fn resolveIp(host: []const u8, port: u16) !Address {
        var buf: [256:0]u8 = undefined;
        if (host.len >= buf.len) return error.NameTooLong;
        @memcpy(buf[0..host.len], host);
        buf[host.len] = 0;
        const host_z: [*:0]const u8 = buf[0..host.len :0];

        var hints: c.addrinfo = std.mem.zeroes(c.addrinfo);
        hints.flags = .{ .NUMERICHOST = true };
        hints.socktype = c.SOCK.DGRAM;

        var result: ?*c.addrinfo = null;
        const rc = c.getaddrinfo(host_z, null, &hints, &result);
        if (@intFromEnum(rc) != 0 or result == null) return error.InvalidAddress;
        defer c.freeaddrinfo(result.?);

        return fromAddrinfo(result.?, port);
    }

    /// DNS resolution with getaddrinfo.
    pub fn resolve(host: []const u8, port: u16) !Address {
        var buf: [256:0]u8 = undefined;
        if (host.len >= buf.len) return error.NameTooLong;
        @memcpy(buf[0..host.len], host);
        buf[host.len] = 0;
        const host_z: [*:0]const u8 = buf[0..host.len :0];

        var hints: c.addrinfo = std.mem.zeroes(c.addrinfo);
        hints.socktype = c.SOCK.DGRAM;

        var result: ?*c.addrinfo = null;
        const rc = c.getaddrinfo(host_z, null, &hints, &result);
        if (@intFromEnum(rc) != 0 or result == null) return error.HostNotFound;
        defer c.freeaddrinfo(result.?);

        return fromAddrinfo(result.?, port);
    }

    fn fromAddrinfo(ai: *const c.addrinfo, port: u16) Address {
        const port_be = std.mem.nativeTo(u16, port, .big);
        var addr: Address = std.mem.zeroes(Address);
        switch (ai.family) {
            posix.AF.INET => {
                const src: *const c.sockaddr.in = @ptrCast(@alignCast(ai.addr.?));
                addr.in = src.*;
                addr.in.port = port_be;
            },
            posix.AF.INET6 => {
                const src: *const c.sockaddr.in6 = @ptrCast(@alignCast(ai.addr.?));
                addr.in6 = src.*;
                addr.in6.port = port_be;
            },
            else => {},
        }
        return addr;
    }
};

/// Unix domain socket address, replacing std.net.Address.initUnix.
pub const UnixAddr = struct {
    addr: c.sockaddr.un,

    pub fn init(path: []const u8) !UnixAddr {
        if (path.len >= @sizeOf(@TypeOf(@as(c.sockaddr.un, undefined).path))) return error.NameTooLong;
        var addr: c.sockaddr.un = .{
            .path = undefined,
        };
        @memcpy(addr.path[0..path.len], path);
        addr.path[path.len] = 0;
        return .{ .addr = addr };
    }

    pub fn sockaddr(self: *UnixAddr) *posix.sockaddr {
        return @ptrCast(&self.addr);
    }

    pub fn socklen(self: *const UnixAddr) posix.socklen_t {
        _ = self;
        return @sizeOf(c.sockaddr.un);
    }
};

pub fn nanoTimestamp() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

pub fn milliTimestamp() i64 {
    return @intCast(@divFloor(nanoTimestamp(), std.time.ns_per_ms));
}

pub fn sleep(ns: u64) void {
    const s: std.c.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&s, null);
}

pub fn close(fd: posix.fd_t) void {
    _ = std.c.close(fd);
}

pub const WriteError = error{
    DiskQuota,
    FileTooBig,
    InputOutput,
    NoSpaceLeft,
    DeviceBusy,
    InvalidArgument,
    AccessDenied,
    BrokenPipe,
    ConnectionResetByPeer,
    WouldBlock,
    Unexpected,
};

pub fn write(fd: posix.fd_t, bytes: []const u8) WriteError!usize {
    const rc = std.c.write(fd, bytes.ptr, bytes.len);
    if (rc >= 0) return @intCast(rc);
    return switch (std.c.errno(rc)) {
        .AGAIN => error.WouldBlock,
        .PIPE => error.BrokenPipe,
        .INVAL => error.InvalidArgument,
        .NOSPC => error.NoSpaceLeft,
        .IO => error.InputOutput,
        .ACCES => error.AccessDenied,
        .CONNRESET => error.ConnectionResetByPeer,
        .DQUOT => error.DiskQuota,
        .FBIG => error.FileTooBig,
        else => error.Unexpected,
    };
}

pub fn socket(domain: u32, sock_type: u32, protocol: u32) !posix.fd_t {
    const rc = std.c.socket(@intCast(domain), @intCast(sock_type), @intCast(protocol));
    if (rc >= 0) return rc;
    return error.Unexpected;
}

pub const ConnectError = error{
    ConnectionRefused,
    WouldBlock,
    Unexpected,
};

pub fn connect(fd: posix.fd_t, addr: *const posix.sockaddr, addrlen: posix.socklen_t) ConnectError!void {
    const rc = std.c.connect(fd, addr, addrlen);
    if (rc == 0) return;
    return switch (std.c.errno(rc)) {
        .CONNREFUSED => error.ConnectionRefused,
        .AGAIN, .INPROGRESS => error.WouldBlock,
        else => error.Unexpected,
    };
}

pub fn bind(fd: posix.fd_t, addr: *const posix.sockaddr, addrlen: posix.socklen_t) !void {
    const rc = std.c.bind(fd, addr, addrlen);
    if (rc == 0) return;
    return switch (std.c.errno(rc)) {
        .ADDRINUSE => error.AddressInUse,
        .ACCES => error.AccessDenied,
        else => error.Unexpected,
    };
}

pub fn listen(fd: posix.fd_t, backlog: u31) !void {
    const rc = std.c.listen(fd, backlog);
    if (rc == 0) return;
    return error.Unexpected;
}

pub fn accept(fd: posix.fd_t, addr: ?*posix.sockaddr, addrlen: ?*posix.socklen_t, flags: u32) !posix.fd_t {
    _ = flags;
    const rc = std.c.accept(fd, addr, addrlen);
    if (rc >= 0) return rc;
    return error.Unexpected;
}

pub fn fcntl(fd: posix.fd_t, cmd: anytype, arg: usize) !u32 {
    const rc = std.c.fcntl(fd, @as(c_int, cmd), arg);
    if (rc >= 0) return @intCast(rc);
    return error.Unexpected;
}

pub const WaitPidResult = struct {
    pid: posix.pid_t,
    status: u32,
};

pub fn waitpid(pid: posix.pid_t, flags: u32) WaitPidResult {
    var status: c_int = 0;
    const rc = std.c.waitpid(pid, &status, @intCast(flags));
    return .{
        .pid = rc,
        .status = @bitCast(status),
    };
}

pub fn mkdirat(dir_fd: posix.fd_t, path: []const u8, mode: posix.mode_t) !void {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const c_path: [*:0]const u8 = buf[0..path.len :0];
    const rc = std.c.mkdirat(dir_fd, c_path, mode);
    if (rc == 0) return;
    return switch (std.c.errno(rc)) {
        .EXIST => error.PathAlreadyExists,
        .ACCES => error.AccessDenied,
        else => error.Unexpected,
    };
}

pub fn setsockopt(fd: posix.fd_t, level: i32, optname: u32, opt: []const u8) !void {
    const rc = std.c.setsockopt(fd, level, optname, opt.ptr, @intCast(opt.len));
    if (rc == 0) return;
    return error.Unexpected;
}

pub fn sendto(fd: posix.fd_t, buf: []const u8, flags: u32, addr: *const posix.sockaddr, addrlen: posix.socklen_t) !usize {
    const rc = std.c.sendto(fd, buf.ptr, buf.len, @intCast(flags), addr, addrlen);
    if (rc >= 0) return @intCast(rc);
    return switch (std.c.errno(rc)) {
        .AGAIN => error.WouldBlock,
        else => error.Unexpected,
    };
}

pub fn recvfrom(fd: posix.fd_t, buf: []u8, flags: u32, addr: *posix.sockaddr, addrlen: *posix.socklen_t) !usize {
    const rc = std.c.recvfrom(fd, buf.ptr, buf.len, @intCast(flags), addr, addrlen);
    if (rc >= 0) return @intCast(rc);
    return switch (std.c.errno(rc)) {
        .AGAIN => error.WouldBlock,
        else => error.Unexpected,
    };
}
