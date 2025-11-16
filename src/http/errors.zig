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
