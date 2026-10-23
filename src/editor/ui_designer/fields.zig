//! Text fields for the UI Properties panel's strings (names, labels, text), which keep their own
//! typing state and follow the value when it changes elsewhere (an undo, a rename in the tree).
const std = @import("std");
const eggy = @import("eggy");
const ui = eggy.ui;

const Edit = ui.TextEdit(256);
const Field = struct { edit: Edit, shown: u64 };

pub const Fields = struct {
    gpa: std.mem.Allocator,
    /// By label: the field's typing state, and the hash of the value it last showed.
    fields: std.AutoHashMapUnmanaged(u64, Field) = .empty,

    pub fn deinit(self: *Fields) void {
        self.fields.deinit(self.gpa);
    }

    /// A text field for `value`: the typed text (in the context's frame arena) when it changed.
    pub fn text(self: *Fields, context: *ui.Context, label: []const u8, value: []const u8, placeholder: []const u8) ?[]const u8 {
        const field = self.fieldFor(label, value) orelse return null;
        if (!context.textInput(label, &field.edit, placeholder)) return null;
        field.shown = std.hash.Wyhash.hash(1, field.edit.text());
        return context.builder().allocator.dupe(u8, field.edit.text()) catch null;
    }

    /// The field for `label`, showing `current` again when the value changed since it last did.
    fn fieldFor(self: *Fields, label: []const u8, current: []const u8) ?*Field {
        const entry = self.fields.getOrPut(self.gpa, std.hash.Wyhash.hash(0, label)) catch return null;
        const hash = std.hash.Wyhash.hash(1, current);
        if (!entry.found_existing) entry.value_ptr.* = .{ .edit = Edit.init("") catch unreachable, .shown = hash +% 1 };
        if (entry.value_ptr.shown != hash) {
            entry.value_ptr.edit.set(current[0..@min(current.len, 256)]) catch {};
            entry.value_ptr.shown = hash;
        }
        return entry.value_ptr;
    }
};
