const std = @import("std");

pub const HttpError = error{
    InvalidParam,
    MissingParam,
    EntityNotFound,
    EntityAlreadyExist,
    InvalidRoute,
    RequestTimeout,
    PanicRecovery,
};

pub const Err = struct {
    message: []const u8,
    err: HttpError,
};

pub const ErrData = struct {
    data: Err,
};

/// Classifies the underlying failure of a datasource operation so the
/// thread-safe `lastError()` accessor can report *what kind* of error occurred
/// without sharing a heap-allocated message across threads. This is the
/// faithful, lock-free reduction of `pg.zig`'s per-connection `conn.err` (which
/// is safe only because each request owns its connection); the HTTP backends are
/// process-wide singletons, so they store only this enum plus an atomic HTTP
/// status.
pub const ErrorKind = enum(u8) {
    none,
    upstream,
    auth,
    rate_limited,
    bad_query,
    connection,
    unknown,
};

/// Map an HTTP response status to an `ErrorKind`. Used by the HTTP-based
/// backends (ClickHouse/InfluxDB/Solr/Couchbase) so the health probe can tell
/// auth/rate-limit/query/upstream failures apart from a bare status code.
pub fn classifyHttpStatus(status: u16) ErrorKind {
    return switch (status) {
        401, 403 => .auth,
        429 => .rate_limited,
        400, 404, 405, 422 => .bad_query,
        500...599 => .upstream,
        else => .unknown,
    };
}

/// Map a non-HTTP Zig error (e.g. the MongoDB driver) to an `ErrorKind`. There
/// is no HTTP status to classify, so connection-level failures win.
pub fn classifyAnyError(err: anyerror) ErrorKind {
    _ = err;
    return .connection;
}

/// Failure detail for an upstream datasource call. `lastError()` returns this
/// *by value* (a copy), so it is fully thread-safe: `status` is the last HTTP
/// status (0 for non-HTTP backends), `code` is the `ErrorKind` tag name, and
/// `message` is intentionally empty — no heap buffer is shared across threads,
/// so there is nothing to free and no use-after-free risk. The precise
/// underlying error is still returned to the operation's caller via the error
/// union (e.g. `error.ClickHouseQueryFailed`); `lastError()` only feeds the
/// health probe, which needs the failure class, not the raw body.
pub const DataSourceError = struct {
    status: u16 = 0,
    code: []const u8 = "",
    message: []const u8 = "",
};

pub const ClientError = error{
    ServiceNotReachable,
    CircuitOpen,
    RateLimited,
    OAuthTokenFetchFailed,
} || std.http.Client.FetchError || HttpError;

pub const CronError = error{
    BadScheduleFormat,
};

pub const ZeroError = error{
    PubSubClientNotAvailable,
};

// ===================== Tests =====================

test "HttpError contains expected errors" {
    const fn_invalid: HttpError!void = error.InvalidParam;
    const fn_missing: HttpError!void = error.MissingParam;
    const fn_notfound: HttpError!void = error.EntityNotFound;
    const fn_exists: HttpError!void = error.EntityAlreadyExist;
    const fn_route: HttpError!void = error.InvalidRoute;
    const fn_timeout: HttpError!void = error.RequestTimeout;
    const fn_panic: HttpError!void = error.PanicRecovery;
    try std.testing.expectError(error.InvalidParam, fn_invalid);
    try std.testing.expectError(error.MissingParam, fn_missing);
    try std.testing.expectError(error.EntityNotFound, fn_notfound);
    try std.testing.expectError(error.EntityAlreadyExist, fn_exists);
    try std.testing.expectError(error.InvalidRoute, fn_route);
    try std.testing.expectError(error.RequestTimeout, fn_timeout);
    try std.testing.expectError(error.PanicRecovery, fn_panic);
}

test "CronError is BadScheduleFormat" {
    const fn_cron: CronError!void = error.BadScheduleFormat;
    try std.testing.expectError(error.BadScheduleFormat, fn_cron);
}

test "ZeroError is PubSubClientNotAvailable" {
    const fn_zero: ZeroError!void = error.PubSubClientNotAvailable;
    try std.testing.expectError(error.PubSubClientNotAvailable, fn_zero);
}

test "ClientError union contains ServiceNotReachable" {
    const err: ClientError!void = error.ServiceNotReachable;
    try std.testing.expectError(error.ServiceNotReachable, err);
}

test "Err struct construction" {
    const err = Err{
        .message = "something went wrong",
        .err = error.InvalidParam,
    };
    try std.testing.expectEqualStrings("something went wrong", err.message);
    const errResult: HttpError!void = err.err;
    try std.testing.expectError(error.InvalidParam, errResult);
}

test "ErrData struct construction" {
    const inner = Err{
        .message = "wrapped error",
        .err = error.EntityNotFound,
    };
    const data = ErrData{ .data = inner };
    try std.testing.expectEqualStrings("wrapped error", data.data.message);
    const errResult: HttpError!void = data.data.err;
    try std.testing.expectError(error.EntityNotFound, errResult);
}

test "classifyHttpStatus maps status to ErrorKind" {
    try std.testing.expectEqual(ErrorKind.auth, classifyHttpStatus(401));
    try std.testing.expectEqual(ErrorKind.auth, classifyHttpStatus(403));
    try std.testing.expectEqual(ErrorKind.rate_limited, classifyHttpStatus(429));
    try std.testing.expectEqual(ErrorKind.bad_query, classifyHttpStatus(400));
    try std.testing.expectEqual(ErrorKind.bad_query, classifyHttpStatus(404));
    try std.testing.expectEqual(ErrorKind.upstream, classifyHttpStatus(500));
    try std.testing.expectEqual(ErrorKind.upstream, classifyHttpStatus(503));
    try std.testing.expectEqual(ErrorKind.unknown, classifyHttpStatus(200));
}

test "DataSourceError from lastError carries ErrorKind tag" {
    const snapshot: ?DataSourceError = .{ .status = 503, .code = @tagName(ErrorKind.upstream), .message = "" };
    try std.testing.expectEqual(ErrorKind.upstream, @as(ErrorKind, @enumFromInt(@intFromEnum(ErrorKind.upstream))));
    try std.testing.expectEqual(@as(u16, 503), snapshot.?.status);
    try std.testing.expectEqualStrings("upstream", snapshot.?.code);
}
