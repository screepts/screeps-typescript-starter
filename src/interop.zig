const std = @import("std");

fn decimal(comptime value: anytype) []const u8 {
    return std.fmt.comptimePrint("{d}", .{value});
}

fn wireFields(comptime Type: type) []const std.builtin.Type.StructField {
    const info = switch (@typeInfo(Type)) {
        .@"struct" => |info| info,
        else => @compileError("Wire records must be extern structs"),
    };
    if (info.layout != .@"extern") @compileError("Wire records must be extern structs");
    return info.fields;
}

fn fieldType(comptime Type: type, comptime name: []const u8) type {
    if (!@hasField(Type, name) or std.mem.startsWith(u8, name, "_")) @compileError("Unknown wire field: " ++ name);
    return @FieldType(Type, name);
}

fn enumName(comptime Type: type) []const u8 {
    const name = @typeName(Type);
    return name[(std.mem.lastIndexOfScalar(u8, name, '.') orelse @compileError("Enum must have a qualified name")) + 1 ..];
}

fn accessor(comptime Type: type) []const u8 {
    return switch (@typeInfo(Type)) {
        .@"enum" => |info| accessor(info.tag_type),
        .bool => "Uint8",
        .int => |info| switch (info.bits) {
            8, 16, 32 => (if (info.signedness == .signed) "Int" else "Uint") ++ decimal(info.bits),
            else => @compileError("Unsupported scalar: " ++ @typeName(Type)),
        },
        else => @compileError("Unsupported scalar: " ++ @typeName(Type)),
    };
}

fn tsType(comptime Type: type) []const u8 {
    return switch (@typeInfo(Type)) {
        .@"struct" => if (@hasDecl(Type, "binding") and @hasField(@TypeOf(Type.binding), "ts_type")) Type.binding.ts_type else @compileError("Missing ts_type binding"),
        .@"enum" => enumName(Type),
        .bool => "boolean",
        .array => |info| if (info.child == u8) "Uint8Array" else @compileError("Only byte arrays are supported"),
        else => blk: {
            _ = accessor(Type);
            break :blk "number";
        },
    };
}

fn writeScalar(comptime Type: type, comptime offset: []const u8, comptime value: []const u8) []const u8 {
    return "this.view.set" ++ accessor(Type) ++ "(" ++ offset ++ ", " ++ value ++
        (if (Type == bool) " ? 1 : 0" else "") ++ (if (@sizeOf(Type) > 1) ", true" else "") ++ ")\n";
}

fn readScalar(comptime Record: type, comptime name: []const u8) []const u8 {
    const Type = fieldType(Record, name);
    return "this.view.get" ++ accessor(Type) ++ "(base + " ++ decimal(@offsetOf(Record, name)) ++
        (if (@sizeOf(Type) > 1) ", true" else "") ++ ")" ++ switch (@typeInfo(Type)) {
        .bool => " !== 0",
        .@"enum" => " as " ++ tsType(Type),
        else => "",
    };
}

fn writeValue(comptime Type: type, comptime offset: usize, comptime value: []const u8) []const u8 {
    if (@typeInfo(Type) == .@"struct") {
        const fields = wireFields(Type);
        if (@hasDecl(Type, "binding") and @hasField(@TypeOf(Type.binding), "codec")) {
            if (!std.mem.eql(u8, Type.binding.codec, "hex_id")) @compileError("Unknown codec: " ++ Type.binding.codec);
            const Bytes = fieldType(Type, Type.binding.bytes);
            const Handle = fieldType(Type, Type.binding.handle);
            const bytes = switch (@typeInfo(Bytes)) {
                .array => |info| info,
                else => @compileError("hex_id requires a byte array and a u32 handle"),
            };
            if (bytes.child != u8 or Handle != u32) @compileError("hex_id requires a byte array and a u32 handle");
            return "this.writeId(" ++ value ++ ", base + " ++ decimal(offset + @offsetOf(Type, Type.binding.bytes)) ++ ", " ++ decimal(bytes.len) ++ ")\n" ++
                writeScalar(Handle, "base + " ++ decimal(offset + @offsetOf(Type, Type.binding.handle)), "this.intern(" ++ value ++ ")");
        }
        var source: []const u8 = "";
        for (fields) |field| {
            if (!std.mem.startsWith(u8, field.name, "_")) source = source ++ writeValue(field.type, offset + @offsetOf(Type, field.name), value ++ "." ++ field.name);
        }
        return source;
    }
    return writeScalar(Type, "base + " ++ decimal(offset), value);
}

fn argumentNames(comptime Record: type) []const []const u8 {
    var names: []const []const u8 = &.{};
    if (@hasField(@TypeOf(Record.binding), "args")) {
        for (Record.binding.args) |name| {
            _ = fieldType(Record, name);
            names = names ++ &[_][]const u8{name};
        }
    } else {
        for (wireFields(Record)) |field| {
            if (!std.mem.startsWith(u8, field.name, "_")) names = names ++ &[_][]const u8{field.name};
        }
    }
    for (wireFields(Record)) |field| {
        if (std.mem.startsWith(u8, field.name, "_")) continue;
        var matches: usize = 0;
        for (names) |name| {
            if (std.mem.eql(u8, name, field.name)) matches += 1;
        }
        if (matches != 1) @compileError("Binding must include every field exactly once");
    }
    return names;
}

test "comptime field writers reflect nested offsets and semantic types" {
    const Position = extern struct {
        x: u8,
        y: u8,
        pub const binding = .{ .ts_type = "RoomPosition" };
    };
    const Record = extern struct {
        energy: u32,
        pos: Position,
        owned: bool,
        pub const binding = .{ .args = .{ "pos", "energy", "owned" } };
    };
    const names = comptime argumentNames(Record);
    try std.testing.expectEqualStrings("pos", names[0]);
    try std.testing.expectEqualStrings("RoomPosition", tsType(Position));
    try std.testing.expectEqualStrings("this.view.setUint8(base + 4, pos.x)\nthis.view.setUint8(base + 5, pos.y)\n", comptime writeValue(Position, @offsetOf(Record, "pos"), "pos"));
    try std.testing.expectEqualStrings("this.view.getUint32(base + 0, true)", comptime readScalar(Record, "energy"));
}

fn enumTypes(comptime Type: type) []const type {
    var types: []const type = &.{};
    switch (@typeInfo(Type)) {
        .@"enum" => return &.{Type},
        .array => |info| return enumTypes(info.child),
        .@"struct" => for (wireFields(Type)) |field| {
            types = types ++ enumTypes(field.type);
        },
        else => {},
    }
    return types;
}

fn emitEnums(comptime types: []const type) []const u8 {
    var source: []const u8 = "";
    for (types, 0..) |Type, index| {
        var seen = false;
        for (types[0..index]) |Previous| {
            if (std.mem.eql(u8, enumName(Type), enumName(Previous))) {
                if (Type != Previous) @compileError("Conflicting enum: " ++ enumName(Type));
                seen = true;
            }
        }
        if (seen) continue;
        source = source ++ "export enum " ++ enumName(Type) ++ " {\n";
        for (@typeInfo(Type).@"enum".fields) |field| {
            source = source ++ field.name ++ " = " ++ decimal(field.value) ++ ",\n";
        }
        source = source ++ "}\n";
    }
    return source;
}

fn sectionRecord(comptime Type: type) type {
    return switch (@typeInfo(Type)) {
        .array => |info| info.child,
        else => Type,
    };
}

fn validateWorld(comptime World: type, comptime input_size: usize) void {
    if (@sizeOf(World) > input_size) @compileError("World exceeds the input buffer");
    const terrain = World.binding.terrain;
    const Terrain = fieldType(World, terrain.field);
    if (@typeInfo(Terrain) != .array or @typeInfo(Terrain).array.child != u8 or @typeInfo(Terrain).array.len * 8 < terrain.room_size * terrain.room_size) @compileError("Terrain must be a sufficiently large byte array");
    if (fieldType(World, terrain.present) != u32) @compileError("Terrain presence must be u32");
    for (World.binding.args) |name| _ = accessor(fieldType(World, name));
    for (World.binding.sections) |section| {
        if (fieldType(World, section.count) != u32) @compileError("Section counts must be u32");
        const Record = sectionRecord(fieldType(World, section.field));
        if (!@hasDecl(Record, "binding") or !@hasField(@TypeOf(Record.binding), "method")) @compileError("Missing writer method: " ++ section.field);
        _ = argumentNames(Record);
    }
    for (wireFields(World)) |field| {
        if (std.mem.startsWith(u8, field.name, "_")) continue;
        var matches: usize = 0;
        for (World.binding.args) |name| {
            if (std.mem.eql(u8, name, field.name)) matches += 1;
        }
        for (World.binding.sections) |section| {
            if (std.mem.eql(u8, section.field, field.name)) matches += 1;
            if (std.mem.eql(u8, section.count, field.name)) matches += 1;
        }
        if (std.mem.eql(u8, terrain.field, field.name)) matches += 1;
        if (std.mem.eql(u8, terrain.present, field.name)) matches += 1;
        if (matches != 1) @compileError("World binding must cover every field exactly once");
    }
}

fn arrayLengthField(comptime Command: type, comptime name: []const u8) []const u8 {
    const length = @field(Command.binding.lengths, name);
    if (fieldType(Command, length) != u32) @compileError("Command array lengths must be u32");
    return length;
}

fn validateCommands(comptime Command: type) void {
    const Opcode = fieldType(Command, Command.binding.discriminant);
    if (@typeInfo(Opcode) != .@"enum") @compileError("Command discriminant must be an enum");
    for (Command.binding.callbacks) |callback| {
        _ = std.meta.stringToEnum(Opcode, callback.method) orelse @compileError("Missing opcode: " ++ callback.method);
        for (callback.args) |name| _ = tsType(fieldType(Command, name));
    }
    for (@typeInfo(Opcode).@"enum".fields) |field| {
        var matches: usize = 0;
        for (Command.binding.callbacks) |callback| {
            if (std.mem.eql(u8, callback.method, field.name)) matches += 1;
        }
        if (matches != 1) @compileError("Every opcode must have one callback");
    }
    for (wireFields(Command)) |field| {
        if (std.mem.startsWith(u8, field.name, "_")) continue;
        if (@typeInfo(field.type) == .array) {
            _ = tsType(field.type);
            _ = arrayLengthField(Command, field.name);
        }
        var used = std.mem.eql(u8, field.name, Command.binding.discriminant);
        for (Command.binding.callbacks) |callback| {
            for (callback.args) |name| {
                if (std.mem.eql(u8, field.name, name)) used = true;
            }
        }
        for (wireFields(Command)) |other| {
            if (@typeInfo(other.type) == .array and std.mem.eql(u8, field.name, arrayLengthField(Command, other.name))) used = true;
        }
        if (!used) @compileError("Command binding omits fields");
    }
}

fn emitSink(comptime Command: type) []const u8 {
    var source: []const u8 = "export interface CommandSink {\n";
    for (Command.binding.callbacks) |callback| {
        source = source ++ callback.method ++ "(";
        for (callback.args, 0..) |name, index| {
            const Type = fieldType(Command, name);
            source = source ++ (if (index > 0) ", " else "") ++ name ++ ": " ++ tsType(Type);
            if (@typeInfo(Type) == .array) source = source ++ ", " ++ name ++ "Length: number";
        }
        source = source ++ "): void\n";
    }
    return source ++ "}\n";
}

const writer_helpers =
    \\id(handle: number): string | undefined {
    \\return this.ids[handle]
    \\}
    \\private intern(id: string): number {
    \\const existing = this.handles.get(id)
    \\if (existing !== undefined) return existing
    \\const handle = this.ids.length
    \\this.ids.push(id)
    \\this.handles.set(id, handle)
    \\return handle
    \\}
    \\private writeId(id: string, offset: number, length: number): void {
    \\if (id.length !== length * 2) throw new RangeError("Invalid object ID length")
    \\for (let index = 0; index < length; index++) {
    \\const high = id.charCodeAt(index * 2)
    \\const low = id.charCodeAt(index * 2 + 1)
    \\this.view.setUint8(offset + index, ((high <= 57 ? high - 48 : (high | 32) - 87) << 4) | (low <= 57 ? low - 48 : (low | 32) - 87))
    \\}
    \\}
;

fn emitWriter(comptime World: type, comptime input_size: usize) []const u8 {
    var source: []const u8 =
        \\export class WorldWriter {
        \\private view: DataView
        \\private readonly ids: (string | undefined)[] = [undefined]
        \\private readonly handles = new Map<string, number>()
    ;
    source = source ++ "\n";
    for (World.binding.sections) |section| source = source ++ "private " ++ section.count ++ " = 0\n";
    source = source ++ "constructor(private readonly memory: WebAssembly.Memory, private readonly ptr: number) {\nthis.view = new DataView(memory.buffer, ptr, " ++ decimal(input_size) ++ ")\n}\nbeginTick(";
    for (World.binding.args, 0..) |name, index| source = source ++ (if (index > 0) ", " else "") ++ name ++ ": " ++ tsType(fieldType(World, name));
    source = source ++ "): void {\nif (this.view.buffer !== this.memory.buffer) this.view = new DataView(this.memory.buffer, this.ptr, " ++ decimal(input_size) ++ ")\nthis.ids.length = 1\nthis.handles.clear()\n";
    for (World.binding.sections) |section| {
        source = source ++ "this." ++ section.count ++ " = 0\n" ++ writeScalar(u32, decimal(@offsetOf(World, section.count)), "0");
    }
    const terrain = World.binding.terrain;
    source = source ++ writeScalar(u32, decimal(@offsetOf(World, terrain.present)), "0");
    for (World.binding.args) |name| source = source ++ writeScalar(fieldType(World, name), decimal(@offsetOf(World, name)), name);
    source = source ++ "}\n" ++ writer_helpers ++ "\n";
    for (World.binding.sections) |section| {
        const Slot = fieldType(World, section.field);
        const Record = sectionRecord(Slot);
        const capacity = if (@typeInfo(Slot) == .array) @typeInfo(Slot).array.len else 1;
        const names = argumentNames(Record);
        source = source ++ Record.binding.method ++ "(";
        for (names, 0..) |name, index| source = source ++ (if (index > 0) ", " else "") ++ name ++ ": " ++ tsType(fieldType(Record, name));
        source = source ++ "): boolean {\nif (this." ++ section.count ++ " >= " ++ decimal(capacity) ++ ") return false\nconst base = " ++ decimal(@offsetOf(World, section.field)) ++ " + this." ++ section.count ++ " * " ++ decimal(@sizeOf(Record)) ++ "\n";
        for (names) |name| source = source ++ writeValue(fieldType(Record, name), @offsetOf(Record, name), name);
        source = source ++ "this." ++ section.count ++ "++\n" ++ writeScalar(u32, decimal(@offsetOf(World, section.count)), "this." ++ section.count) ++ "return true\n}\n";
    }
    const Terrain = fieldType(World, terrain.field);
    source = source ++ "writeTerrain(terrain: RoomTerrain): void {\nfor (let index = 0; index < " ++ decimal(@typeInfo(Terrain).array.len) ++ "; index++) this.view.setUint8(" ++ decimal(@offsetOf(World, terrain.field)) ++ " + index, 0)\n" ++
        "for (let y = 0; y < " ++ decimal(terrain.room_size) ++ "; y++) {\nfor (let x = 0; x < " ++ decimal(terrain.room_size) ++ "; x++) {\nif ((terrain.get(x, y) & TERRAIN_MASK_WALL) !== 0) {\nconst index = y * " ++ decimal(terrain.room_size) ++ " + x\nconst offset = " ++ decimal(@offsetOf(World, terrain.field)) ++ " + (index >> 3)\nthis.view.setUint8(offset, this.view.getUint8(offset) | (1 << (index & 7)))\n}\n}\n}\n" ++
        writeScalar(u32, decimal(@offsetOf(World, terrain.present)), "1") ++ "}\n}\n";
    return source;
}

fn emitReader(comptime Command: type, comptime input_size: usize) []const u8 {
    var source: []const u8 = "export class CommandReader {\nprivate view: DataView\n";
    for (wireFields(Command)) |field| {
        if (@typeInfo(field.type) == .array) source = source ++ "private readonly " ++ field.name ++ " = new Uint8Array(" ++ decimal(@typeInfo(field.type).array.len) ++ ")\n";
    }
    source = source ++ "constructor(private readonly memory: WebAssembly.Memory, private readonly ptr: number) {\nthis.view = new DataView(memory.buffer, ptr + " ++ decimal(input_size) ++ ", " ++ decimal(input_size) ++ ")\n}\n" ++
        "dispatch(written: number, sink: CommandSink): void {\nif (this.view.buffer !== this.memory.buffer) this.view = new DataView(this.memory.buffer, this.ptr + " ++ decimal(input_size) ++ ", " ++ decimal(input_size) ++ ")\n" ++
        "if (written < 4 || written > " ++ decimal(input_size) ++ ") throw new RangeError(\"Invalid command buffer length\")\nconst count = this.view.getUint32(0, true)\n" ++
        "if (4 + count * " ++ decimal(@sizeOf(Command)) ++ " > written) throw new RangeError(\"Truncated command buffer\")\nfor (let index = 0; index < count; index++) {\nconst base = 4 + index * " ++ decimal(@sizeOf(Command)) ++ "\nswitch (" ++ readScalar(Command, Command.binding.discriminant) ++ ") {\n";
    const Opcode = fieldType(Command, Command.binding.discriminant);
    for (Command.binding.callbacks) |callback| {
        const opcode = @intFromEnum(@field(Opcode, callback.method));
        source = source ++ "case " ++ decimal(opcode) ++ ": {\n";
        for (callback.args) |name| {
            const Type = fieldType(Command, name);
            if (@typeInfo(Type) == .array) {
                source = source ++ "const " ++ name ++ "Length = " ++ readScalar(Command, arrayLengthField(Command, name)) ++ "\nif (" ++ name ++ "Length > " ++ decimal(@typeInfo(Type).array.len) ++ ") throw new RangeError(\"Command array exceeds capacity\")\n" ++
                    "for (let index = 0; index < " ++ name ++ "Length; index++) this." ++ name ++ "[index] = this.view.getUint8(base + " ++ decimal(@offsetOf(Command, name)) ++ " + index)\n";
            }
        }
        source = source ++ "sink." ++ callback.method ++ "(";
        for (callback.args, 0..) |name, index| {
            source = source ++ (if (index > 0) ", " else "") ++ if (@typeInfo(fieldType(Command, name)) == .array) "this." ++ name ++ ", " ++ name ++ "Length" else readScalar(Command, name);
        }
        source = source ++ ")\nbreak\n}\n";
    }
    return source ++ "default: throw new Error(\"Unknown command opcode\")\n}\n}\n}\n}\n";
}

pub fn typescript(comptime World: type, comptime Command: type, comptime Role: type, comptime Part: type, comptime input_size: usize, comptime amount_all: usize) []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(1_000_000);
        validateWorld(World, input_size);
        validateCommands(Command);
        break :blk emitEnums(enumTypes(World) ++ enumTypes(Command) ++ &[_]type{ Role, Part }) ++
            "export const AMOUNT_ALL = " ++ decimal(amount_all) ++ "\n" ++ emitSink(Command) ++ emitWriter(World, input_size) ++ emitReader(Command, input_size);
    };
}
