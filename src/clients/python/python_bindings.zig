const std = @import("std");
const vsr = @import("vsr");
const tb_client = vsr.tb_client;
const assert = std.debug.assert;

const constants = vsr.constants;
const IO = vsr.io.IO;

const Storage = vsr.storage.StorageType(IO);
const StateMachine = vsr.state_machine.StateMachineType(Storage, constants.state_machine_config);
const tb = vsr.tigerbeetle;

/// VSR type mappings: these will always be the same regardless of state machine.
const mappings_vsr = .{
    .{ tb_client.tb_operation_t, "Operation" },
    .{ tb_client.tb_packet_status_t, "PacketStatus" },
    .{ tb_client.tb_packet_t, "Packet" },
    .{ tb_client.tb_client_t, "Client" },
    .{ tb_client.tb_status_t, "Status" },
};

/// State machine specific mappings: in future, these should be pulled automatically from the state
/// machine.
const mappings_state_machine = .{
    .{ tb.AccountFlags, "AccountFlags" },
    .{ tb.TransferFlags, "TransferFlags" },
    .{ tb.AccountFilterFlags, "AccountFilterFlags" },
    .{ tb.QueryFilterFlags, "QueryFilterFlags" },
    .{ tb.Account, "Account" },
    .{ tb.Transfer, "Transfer" },
    .{ tb.CreateAccountResult, "CreateAccountResult" },
    .{ tb.CreateTransferResult, "CreateTransferResult" },
    .{ tb.CreateAccountsResult, "CreateAccountsResult" },
    .{ tb.CreateTransfersResult, "CreateTransfersResult" },
    .{ tb.AccountFilter, "AccountFilter" },
    .{ tb.AccountBalance, "AccountBalance" },
    .{ tb.QueryFilter, "QueryFilter" },
};

const mappings_all = mappings_vsr ++ mappings_state_machine;

const Buffer = struct {
    inner: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Buffer {
        return .{
            .inner = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn print(self: *Buffer, comptime format: []const u8, args: anytype) void {
        self.inner.writer().print(format, args) catch unreachable;
    }
};

fn mapping_name_from_type(mappings: anytype, Type: type) ?[]const u8 {
    comptime for (mappings) |mapping| {
        const ZigType, const python_name = mapping;

        if (Type == ZigType) {
            return python_name;
        }
    };
    return null;
}

/// Resolves a Zig Type into a string representing the name of a corresponding Python ctype. This
/// resolves both VSR and state machine specific mappings, as both are needed when interfacing via
/// FFI.
fn zig_to_ctype(comptime Type: type) []const u8 {
    switch (@typeInfo(Type)) {
        .Array => |info| {
            return std.fmt.comptimePrint("{s} * {d}", .{
                comptime zig_to_ctype(info.child),
                info.len,
            });
        },
        .Enum => |info| return zig_to_ctype(info.tag_type),
        .Struct => return zig_to_ctype(std.meta.Int(.unsigned, @bitSizeOf(Type))),
        .Bool => return "ctypes.c_bool",
        .Int => |info| {
            assert(info.signedness == .unsigned);
            return switch (info.bits) {
                8 => "ctypes.c_uint8",
                16 => "ctypes.c_uint16",
                32 => "ctypes.c_uint32",
                64 => "ctypes.c_uint64",
                128 => "c_uint128",
                else => @compileError("invalid int type"),
            };
        },
        .Optional => |info| switch (@typeInfo(info.child)) {
            .Pointer => return zig_to_ctype(info.child),
            else => @compileError("Unsupported optional type: " ++ @typeName(Type)),
        },
        .Pointer => |info| {
            assert(info.size == .One);
            assert(!info.is_allowzero);

            if (Type == *anyopaque) {
                return "ctypes.c_void_p";
            }

            return comptime "ctypes.POINTER(C" ++
                mapping_name_from_type(mappings_all, info.child).? ++
                ")";
        },
        .Void => return "None",
        else => @compileError("Unhandled type: " ++ @typeName(Type)),
    }
}

/// Resolves a Zig Type into a string representing the name of a corresponding Python dataclass.
/// Unlike zig_to_ctype, this only resolves state machine specific mappings: VSR mappings are
/// internal to the client, and not exposed to calling code.
fn zig_to_python(comptime Type: type) []const u8 {
    switch (@typeInfo(Type)) {
        .Enum => return comptime mapping_name_from_type(mappings_state_machine, Type).?,
        .Array => |info| {
            return std.fmt.comptimePrint("{s}[{d}]", .{
                comptime zig_to_python(info.child),
                info.len,
            });
        },
        .Struct => return comptime mapping_name_from_type(mappings_state_machine, Type).?,
        .Bool => return "bool",
        .Int => |info| {
            assert(info.signedness == .unsigned);
            return switch (info.bits) {
                8 => "int",
                16 => "int",
                32 => "int",
                64 => "int",
                128 => "int",
                else => @compileError("invalid int type"),
            };
        },
        .Void => return "None",
        else => @compileError("Unhandled type: " ++ @typeName(Type)),
    }
}

fn to_uppercase(comptime input: []const u8) [input.len]u8 {
    comptime var output: [input.len]u8 = undefined;
    inline for (&output, 0..) |*char, i| {
        char.* = input[i];
        char.* -= 32 * @as(u8, @intFromBool(char.* >= 'a' and char.* <= 'z'));
    }
    return output;
}

fn emit_enum(
    buffer: *Buffer,
    comptime Type: type,
    comptime type_info: anytype,
    comptime python_name: []const u8,
    comptime skip_fields: []const []const u8,
) !void {
    if (@typeInfo(Type) == .Enum) {
        buffer.print("class {s}(enum.IntEnum):\n", .{python_name});
    } else {
        // Packed structs.
        assert(@typeInfo(Type) == .Struct and @typeInfo(Type).Struct.layout == .@"packed");

        buffer.print("class {s}(enum.IntFlag):\n", .{python_name});
        buffer.print("    NONE = 0\n", .{});
    }

    inline for (type_info.fields, 0..) |field, i| {
        comptime var skip = false;
        inline for (skip_fields) |sf| {
            skip = skip or comptime std.mem.eql(u8, sf, field.name);
        }

        if (!skip) {
            const field_name = to_uppercase(field.name);
            if (@typeInfo(Type) == .Enum) {
                buffer.print("    {s} = {}\n", .{
                    @as([]const u8, &field_name),
                    @intFromEnum(@field(Type, field.name)),
                });
            } else {
                // Packed structs.
                buffer.print("    {s} = 1 << {}\n", .{
                    @as([]const u8, &field_name),
                    i,
                });
            }
        }
    }

    buffer.print("\n\n", .{});
}

fn emit_struct_ctypes(
    buffer: *Buffer,
    comptime type_info: anytype,
    comptime c_name: []const u8,
    generate_ctypes_to_python: bool,
) !void {
    buffer.print(
        \\class C{[type_name]s}(ctypes.Structure):
        \\    @classmethod
        \\    def from_param(cls, obj):
        \\
    , .{
        .type_name = c_name,
    });

    inline for (type_info.fields) |field| {
        const field_type_info = @typeInfo(field.type);

        // Emit a bounds check for all integer types that aren't using the custom c_uint128 class.
        // That has an explicit check built in, but the standard Python ctypes ones (eg,
        // ctypes.c_uint64) don't and will happily overflow otherwise.
        if (comptime !std.mem.eql(u8, field.name, "reserved") and field_type_info == .Int) {
            buffer.print("        validate_uint(bits={[int_bits]}, name=\"{[field_name]s}\", " ++
                "number=obj.{[field_name]s})\n", .{
                .field_name = field.name,
                .int_bits = field_type_info.Int.bits,
            });
        }
    }

    buffer.print("        return cls(\n", .{});

    inline for (type_info.fields) |field| {
        const field_type_info = @typeInfo(field.type);
        const field_is_u128 = field_type_info == .Int and field_type_info.Int.bits == 128;
        const convert_prefix = if (field_is_u128) "c_uint128.from_param(" else "";
        const convert_suffix = if (field_is_u128) ")" else "";

        if (comptime !std.mem.eql(u8, field.name, "reserved")) {
            buffer.print("            {[field_name]s}={[convert_prefix]s}" ++
                "obj.{[field_name]s}{[convert_suffix]s},\n", .{
                .field_name = field.name,
                .convert_prefix = convert_prefix,
                .convert_suffix = convert_suffix,
            });
        }
    }
    buffer.print("        )\n\n", .{});

    if (generate_ctypes_to_python) {
        buffer.print(
            \\
            \\    def to_python(self):
            \\        return {[type_name]s}(
            \\
        , .{
            .type_name = c_name,
        });

        inline for (type_info.fields) |field| {
            if (comptime !std.mem.eql(u8, field.name, "reserved")) {
                buffer.print("            {s}={s},\n", .{
                    field.name,
                    convert_ctypes_to_python("self." ++ field.name, field.type),
                });
            }
        }
        buffer.print("        )\n\n", .{});
    }

    buffer.print("C{s}._fields_ = [ # noqa: SLF001\n", .{c_name});

    inline for (type_info.fields) |field| {
        buffer.print("    (\"{s}\", {s}),", .{
            field.name,
            zig_to_ctype(field.type),
        });

        buffer.print("\n", .{});
    }

    buffer.print("]\n\n\n", .{});
}

fn convert_ctypes_to_python(comptime name: []const u8, comptime Type: type) []const u8 {
    inline for (mappings_state_machine) |type_mapping| {
        const ZigType, const python_name = type_mapping;

        if (ZigType == Type) {
            return python_name ++ "(" ++ name ++ ")";
        }
    }
    if (@typeInfo(Type) == .Int and @typeInfo(Type).Int.bits == 128) {
        return name ++ ".to_python()";
    }

    return name;
}

fn emit_struct_dataclass(
    buffer: *Buffer,
    comptime type_info: anytype,
    comptime c_name: []const u8,
) !void {
    buffer.print("@dataclass\n", .{});
    buffer.print("class {s}:\n", .{c_name});

    inline for (type_info.fields) |field| {
        const field_type_info = @typeInfo(field.type);
        if (comptime !std.mem.eql(u8, field.name, "reserved")) {
            const python_type = zig_to_python(field.type);
            buffer.print("    {[name]s}: {[python_type]s} = ", .{
                .name = field.name,
                .python_type = python_type,
            });

            if (field_type_info == .Struct and field_type_info.Struct.layout == .@"packed") {
                buffer.print("{s}.NONE\n", .{python_type});
            } else {
                buffer.print("0\n", .{});
            }
        }
    }

    buffer.print("\n\n", .{});
}

fn ctype_type_name(comptime Type: type) []const u8 {
    if (Type == u128) {
        return "c_uint128";
    }

    return comptime "C" ++ mapping_name_from_type(mappings_all, Type).?;
}

fn emit_method(buffer: *Buffer, comptime operation: std.builtin.Type.EnumField, options: struct {
    is_async: bool,
}) void {
    const op: StateMachine.Operation = @enumFromInt(operation.value);

    const event_type = comptime if (StateMachine.event_is_slice(op))
        "list[" ++ zig_to_python(StateMachine.EventType(op)) ++ "]"
    else
        zig_to_python(StateMachine.EventType(op));

    const result_type =
        comptime "list[" ++ zig_to_python(StateMachine.ResultType(op)) ++ "]";

    // For ergonomics, the client allows calling things like .query_accounts(filter) even
    // though the _submit function requires a list for everything. Wrap them here.
    const event_name_or_list = comptime if (!StateMachine.event_is_slice(op))
        "[" ++ StateMachine.event_name(op) ++ "]"
    else
        StateMachine.event_name(op);

    buffer.print(
        \\    {[prefix_fn]s}def {[fn_name]s}(self, {[event_name]s}: {[event_type]s}) -> {[result_type]s}:
        \\        return {[prefix_call]s}self._submit(
        \\            Operation.{[uppercase_name]s},
        \\            {[event_name_or_list]s},
        \\            {[event_type_c]s},
        \\            {[result_type_c]s},
        \\        )
        \\
        \\
    ,
        .{
            .prefix_fn = if (options.is_async) "async " else "",
            .fn_name = operation.name,
            .event_name = StateMachine.event_name(op),
            .event_type = event_type,
            .result_type = result_type,
            .event_name_or_list = event_name_or_list,
            .prefix_call = if (options.is_async) "await " else "",
            .uppercase_name = to_uppercase(operation.name),
            .event_type_c = ctype_type_name(StateMachine.EventType(op)),
            .result_type_c = ctype_type_name(StateMachine.ResultType(op)),
        },
    );
}

pub fn main() !void {
    @setEvalBranchQuota(100_000);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var buffer = Buffer.init(allocator);
    buffer.print(
        \\##########################################################
        \\## This file was auto-generated by tb_client_header.zig ##
        \\##              Do not manually modify.                 ##
        \\##########################################################
        \\from __future__ import annotations
        \\
        \\import ctypes
        \\import enum
        \\from collections.abc import Callable # noqa: TCH003
        \\from typing import Any
        \\
        \\from .lib import c_uint128, dataclass, tbclient, validate_uint
        \\
        \\
        \\
    , .{});

    // Emit enum and direct declarations.
    inline for (mappings_all) |type_mapping| {
        const ZigType, const python_name = type_mapping;

        switch (@typeInfo(ZigType)) {
            .Struct => |info| switch (info.layout) {
                .auto => @compileError("Invalid C struct type: " ++ @typeName(ZigType)),
                .@"packed" => try emit_enum(&buffer, ZigType, info, python_name, &.{"padding"}),
                .@"extern" => continue,
            },
            .Enum => |info| {
                comptime var skip: []const []const u8 = &.{};
                if (ZigType == tb_client.tb_operation_t) {
                    skip = &.{ "reserved", "root", "register" };
                }

                try emit_enum(&buffer, ZigType, info, python_name, skip);
            },
            else => buffer.print("{s} = {s}\n\n", .{
                python_name,
                zig_to_ctype(ZigType),
            }),
        }
    }

    // Emit dataclass declarations
    inline for (mappings_state_machine) |type_mapping| {
        const ZigType, const python_name = type_mapping;

        // Enums, non-extern structs and everything else have been emitted by the first pass.
        switch (@typeInfo(ZigType)) {
            .Struct => |info| switch (info.layout) {
                .@"extern" => try emit_struct_dataclass(&buffer, info, python_name),
                else => {},
            },
            else => {},
        }
    }

    // Emit ctype struct and enum type declarations.
    inline for (mappings_all) |type_mapping| {
        const ZigType, const python_name = type_mapping;

        // VSR ctype structs don't have a corresponding Python dataclass - so don't generate the
        // `def to_python(self):` method for them.
        const generate_ctypes_to_python = comptime mapping_name_from_type(
            mappings_state_machine,
            ZigType,
        ) != null;

        switch (@typeInfo(ZigType)) {
            .Struct => |info| switch (info.layout) {
                .auto => @compileError("Invalid C struct type: " ++ @typeName(ZigType)),
                .@"packed" => continue,
                .@"extern" => try emit_struct_ctypes(
                    &buffer,
                    info,
                    python_name,
                    generate_ctypes_to_python,
                ),
            },
            else => continue,
        }
    }

    // Emit function declarations corresponding to the underlying libtbclient exported functions.
    // TODO: use `std.meta.declaractions` and generate with pub + export functions.
    buffer.print(
        \\# Don't be tempted to use c_char_p for bytes_ptr - it's for null terminated strings only.
        \\OnCompletion = ctypes.CFUNCTYPE(None, ctypes.c_void_p, Client, ctypes.POINTER(CPacket),
        \\                                ctypes.c_uint64, ctypes.c_void_p, ctypes.c_uint32)
        \\
        \\# Initialize a new TigerBeetle client which connects to the addresses provided and
        \\# completes submitted packets by invoking the callback with the given context.
        \\tb_client_init = tbclient.tb_client_init
        \\tb_client_init.restype = Status
        \\tb_client_init.argtypes = [ctypes.POINTER(Client), c_uint128, ctypes.c_char_p,
        \\                           ctypes.c_uint32, ctypes.c_void_p, OnCompletion]
        \\
        \\# Initialize a new TigerBeetle client which echos back any data submitted.
        \\tb_client_init_echo = tbclient.tb_client_init_echo
        \\tb_client_init_echo.restype = Status
        \\tb_client_init.argtypes = [ctypes.POINTER(Client), c_uint128, ctypes.c_char_p,
        \\                           ctypes.c_uint32, ctypes.c_void_p, OnCompletion]
        \\
        \\# Closes the client, causing any previously submitted packets to be completed with
        \\# `TB_PACKET_CLIENT_SHUTDOWN` before freeing any allocated client resources from init.
        \\# It is undefined behavior to use any functions on the client once deinit is called.
        \\tb_client_deinit = tbclient.tb_client_deinit
        \\tb_client_deinit.restype = None
        \\tb_client_deinit.argtypes = [Client]
        \\
        \\# Submit a packet with its operation, data, and data_size fields set.
        \\# Once completed, `on_completion` will be invoked with `on_completion_ctx` and the given
        \\# packet on the `tb_client` thread (separate from caller's thread).
        \\tb_client_submit = tbclient.tb_client_submit
        \\tb_client_submit.restype = None
        \\tb_client_submit.argtypes = [Client, ctypes.POINTER(CPacket)]
        \\
    , .{});

    inline for (.{ true, false }) |is_async| {
        const prefix_class = if (is_async) "Async" else "";

        buffer.print(
            \\class {s}StateMachineMixin:
            \\    _submit: Callable[[Operation, Any, Any, Any], Any]
            \\
        , .{prefix_class});

        inline for (std.meta.fields(StateMachine.Operation)) |operation| {
            const op: StateMachine.Operation = @enumFromInt(operation.value);
            // TODO: Pulse shouldn't be hardcoded.
            if (op != .pulse) {
                emit_method(&buffer, operation, .{ .is_async = is_async });
            }
        }

        buffer.print("\n\n", .{});
    }

    try std.io.getStdOut().writeAll(buffer.inner.items);
}