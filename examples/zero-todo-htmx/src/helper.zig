const std = @import("std");
const zero = @import("zero");

const App = zero.App;
const Context = zero.Context;
const utils = zero.utils;
const Builder = zero.zul.StringBuilder;
const models = @import("models.zig");

const Self = @This();
const Helper = @This();

const liItem = "<li class=\"py-4 fade-me-out fade-me-in\" id='LISTITEM'>";
const input = "<input id='ID' name='NAME' type='checkbox' class='h-4 w-4 text-teal-600 focus:ring-teal-500 border-gray-300 rounded' hx-post='POST' hx-target='TARGET' hx-swap='outerHTML settle:0.25s'>";
const inputChecked = "<input id='ID' name='NAME' type='checkbox' class='h-4 w-4 text-teal-600 focus:ring-teal-500 border-gray-300 rounded' hx-post='POST' hx-target='TARGET' hx-swap='outerHTML settle:0.25s' checked>";

const label1 = "<label for='ID' class='ml-3 block text-gray-900 grow'>";

const titleSpan = "<span class='text-lg font-medium'>TITLE  </span>";
const titleSpanDone = "<span class='text-lg font-medium line-through'>TITLE  </span>";

const descSpan = "<br><span class='text-sm font-light text-gray-500'>DESCRIPTION </span>";
const descSpanDone = "<br><span class='text-sm font-light text-gray-500 line-through'>DESCRIPTION </span>";

const editButton = "<button title='EDIT' class='transition ease-in-out delay-150 hover:-translate-y-1 hover:scale-110 p-2' hx-get='EDIT' hx-target='TARGET' hx-swap='outerHTML settle:0.25s'>✏️</button>";
const deleteButton = "<button title='DELETE' class='transition ease-in-out delay-150 hover:-translate-y-1 hover:scale-110 p-2' hx-delete='DELETE' hx-target='TARGET' hx-swap='delete swap:0.25s'>❌</button>";

const editItem = "<li class='py-4 fade-me-in' id='EDITITEM'>";
const editForm = "<form class='flex items-center' hx-ext='json-enc' hx-put='UPDATEITEM' hx-target='TARGET' hx-swap='outerHTML settle:0.25s'>";
const editTitle = "<input class='appearance-none bg-transparent border-none w-full text-lg font-medium text-gray-700 mr-3 py-1 px-2 leading-tight focus:outline-none' type='text' placeholder='Task title' name='task' value='TITLE' required>";
const editDescription = "<input class='appearance-none bg-transparent border-none w-full text-gray-700 mr-3 py-1 px-2 leading-tight focus:outline-none' type='text' placeholder='Task description' name='description' value='DESCRIPTION'>";
const editSaveAction = "<button title='Save' class='transition ease-in-out delay-150 hover:-translate-y-1 hover:scale-110' type='submit'>✔️</button>";

pub fn getEditItem(ctx: *Context, todo: *models.HandlerTodo) ![]const u8 {
    var sb = Builder.init(ctx.allocator);

    const EDITITEM = try utils.combine(ctx.allocator, "list-item-edit-{s}", .{todo.id.?});
    const TARGET = try utils.combine(ctx.allocator, "#list-item-edit-{s}", .{todo.id.?});
    const UPDATE = try utils.combine(ctx.allocator, "/todos/{s}", .{todo.id.?});

    try sb.write(replace(ctx.allocator, editItem, "EDITITEM", EDITITEM));

    var id = replace(ctx.allocator, editForm, "UPDATEITEM", UPDATE);
    id = replace(ctx.allocator, id, "TARGET", TARGET);
    try sb.write(id);

    try sb.write("<div class=\"ml-3 block text-gray-900 grow\">");
    try sb.write(replace(ctx.allocator, editTitle, "TITLE", todo.task.?));
    try sb.write(replace(ctx.allocator, editDescription, "DESCRIPTION", todo.description.?));
    try sb.write("</div>");
    try sb.write(editSaveAction);
    try sb.write("</form>");
    try sb.write("</li>");

    return sb.string();
}

pub fn itemList(ctx: *Context, items: std.array_list.Managed(models.HandlerTodo)) ![]const u8 {
    var sb = Builder.init(ctx.allocator);

    try sb.write("<ul class=\"divide-y divide-gray-200 px-4 grid\" id=\"list\">");
    for (items.items) |item| {
        try innerHtmlItem(ctx.allocator, &sb, &item);
    }
    try sb.write("</ul>");

    return sb.string();
}

pub fn innerHtmlItem(allocator: std.mem.Allocator, sb: *Builder, todo: *const models.HandlerTodo) !void {
    const LISTITEM = try utils.combine(allocator, "list-item-{s}", .{todo.id.?});
    const ID = try utils.combine(allocator, "list-item-check-{s}", .{todo.id.?});
    const NAME = try utils.combine(allocator, "todo{s}", .{todo.id.?});
    const TARGET = try utils.combine(allocator, "#list-item-{s}", .{todo.id.?});
    const EDIT = try utils.combine(allocator, "/todos/{s}", .{todo.id.?});
    const DELETE = try utils.combine(allocator, "/todos/{s}", .{todo.id.?});

    var POST = try utils.combine(allocator, "/done/{s}", .{todo.id.?});
    if (todo.isDone.? == true) {
        POST = try utils.combine(allocator, "/undone/{s}", .{todo.id.?});
    }

    var id: []u8 = undefined;
    if (todo.isDone.? == true) {
        id = replace(allocator, inputChecked, "ID", ID);
        id = replace(allocator, id, "NAME", NAME);
        id = replace(allocator, id, "POST", POST);
        id = replace(allocator, id, "TARGET", TARGET);
    } else {
        id = replace(allocator, input, "ID", ID);
        id = replace(allocator, id, "NAME", NAME);
        id = replace(allocator, id, "POST", POST);
        id = replace(allocator, id, "TARGET", TARGET);
    }

    try sb.write(replace(allocator, liItem, "LISTITEM", LISTITEM));
    try sb.write("<div class=\"flex items-center\">");
    try sb.write(id);
    try sb.write(replace(allocator, label1, "ID", ID));

    if (todo.isDone.? == true) {
        try sb.write(replace(allocator, titleSpanDone, "TITLE", todo.task.?));
    } else {
        try sb.write(replace(allocator, titleSpan, "TITLE", todo.task.?));
    }

    if (todo.isDone.? == true) {
        try sb.write(replace(allocator, descSpanDone, "DESCRIPTION", todo.description.?));
    } else {
        try sb.write(replace(allocator, descSpan, "DESCRIPTION", todo.description.?));
    }

    try sb.write("</label>");
    try sb.write("<div class=\"p-2\">");

    if (todo.isDone.? == false) {
        id = replace(allocator, editButton, "EDIT", EDIT);
        id = replace(allocator, id, "TARGET", TARGET);
        try sb.write(id);
    }

    id = replace(allocator, deleteButton, "DELETE", DELETE);
    id = replace(allocator, id, "TARGET", TARGET);
    try sb.write(id);

    try sb.write("</div>");
    try sb.write("</div>");
    try sb.write("</li>");
}

fn replace(allocator: std.mem.Allocator, source: []const u8, needle: []const u8, word: []const u8) []u8 {
    const new_size = std.mem.replacementSize(u8, source, needle, word);

    const dest: []u8 = allocator.alloc(u8, new_size) catch unreachable;
    _ = std.mem.replace(u8, source, needle, word, dest);
    return dest;
}
