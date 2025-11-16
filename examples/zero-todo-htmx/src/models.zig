const std = @import("std");
const models = @This();
const Self = @This();

pub const addTodoEntry = "INSERT INTO todos(task, description) values ($1, $2)";
pub const getTodoEntry = "SELECT * from todos order by id desc limit 1;";
pub const getTodoByID = "SELECT * from todos WHERE id = $1;";
pub const getAllTodos = "SELECT * FROM todos ORDER BY id desc LIMIT 100;";
pub const updateTodo = "UPDATE todos SET task=$1, description=$2 WHERE id = $3;";
pub const updateDone = "UPDATE todos SET is_done = $1 WHERE id = $2;";
pub const deleteTodo = "DELETE from todos WHERE id = $1;";

pub const data = struct {
    message: []const u8,
};

pub const Todo = struct {
    id: ?i32 = 0,
    task: ?[]const u8 = undefined,
    description: ?[]const u8 = undefined,
    isDone: ?bool = undefined,
    created_at: ?i64 = undefined,
};

pub const HandlerTodo = struct {
    id: ?[]const u8 = undefined,
    task: ?[]const u8 = undefined,
    description: ?[]const u8 = undefined,
    created_at: ?[]const u8 = undefined,
    isDone: ?bool = undefined,
};
