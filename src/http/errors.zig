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

pub const ClientError = error{
    ServiceNotReachable,
} || std.http.Client.FetchError || HttpError;

pub const CronError = error{
    BadScheduleFormat,
};

pub const ZeroError = error{
    PubSubClientNotAvailable,
};

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
