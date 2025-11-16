pub const Response = struct {
    message: anyopaque,
};

pub const ErrData = struct {
    data: Response,
};
