const std = @import("std");
const builtin = @import("builtin");
const spud = @import("spud");
const interop = @import("interop.zig");

// pub const std_options_debug_io: std.Io = if (builtin.target.isWasm() and
//     builtin.target.os.tag == .freestanding)
//     std.Io.failing
// else
//     std.Options.debug_threaded_io.?.io();

// Wasm-boundary tooling lives here, not in root.zig: byte layout, the shared
// scratch buffer, and translating wire records <-> root.zig's structured
// TickInput/Command types are wasm-specific concerns, while root.zig is a
// plain, natively-testable game library.
//
// Wire records use the C ABI and are memory-mapped onto the scratch buffer.
// Nested types and records own their binding metadata. interop.zig reflects
// their wasm32 layout directly into TypeScript source at comptime.

const ObjectId = spud.ObjectId;

fn Id(comptime target: []const u8) type {
    return extern struct {
        id: ObjectId,
        handle: u32,

        pub const binding = .{ .ts_type = "Id<" ++ target ++ ">", .codec = "hex_id", .bytes = "id", .handle = "handle" };
    };
}

const Position = extern struct {
    x: u8,
    y: u8,

    pub const binding = .{ .ts_type = "RoomPosition" };
};

comptime {
    std.debug.assert(@sizeOf(Id("StructureSpawn")) == 16);
    std.debug.assert(@offsetOf(Id("StructureSpawn"), "handle") == 12);
}

const ControllerRecord = extern struct {
    level: u32,
    progress: u32,
    progressTotal: u32,
    id: Id("StructureController"),
    pos: Position,
    owned: bool,
    _pad: u8 = 0,

    pub const binding = .{ .method = "writeController", .args = .{ "id", "pos", "level", "progress", "progressTotal", "owned" } };
};
const SpawnRecord = extern struct {
    energy: u32,
    energyCapacity: u32,
    id: Id("StructureSpawn"),
    pos: Position,
    spawning: bool,
    _pad: u8 = 0,

    pub const binding = .{ .method = "writeSpawn", .args = .{ "id", "pos", "energy", "energyCapacity", "spawning" } };
};
const SourceRecord = extern struct {
    energy: u32,
    energyCapacity: u32,
    id: Id("Source"),
    pos: Position,
    _pad: u16 = 0,

    pub const binding = .{ .method = "writeSource", .args = .{ "id", "pos", "energy", "energyCapacity" } };
};
const CreepRecord = extern struct {
    carry: u32,
    carryCapacity: u32,
    id: Id("Creep"),
    pos: Position,
    role: spud.Role,
    workParts: u8,
    carryParts: u8,
    moveParts: u8,
    spawning: bool,
    _pad: u8 = 0,

    pub const binding = .{ .method = "writeCreep", .args = .{ "id", "pos", "carry", "carryCapacity", "role", "workParts", "carryParts", "moveParts", "spawning" } };
};
const DroppedRecord = extern struct {
    amount: u32,
    id: Id("Resource"),
    pos: Position,
    _pad: u16 = 0,

    pub const binding = .{ .method = "writeDropped", .args = .{ "id", "pos", "amount" } };
};
/// The full tick snapshot, memory-mapped directly onto the input half of
/// scratchPad. Binding metadata associates record sections with their counts;
/// field offsets, element strides, and capacities are reflected by the compiler.
const World = extern struct {
    tick: u32 = 0,
    cpuBucket: u32 = 0,
    roomWx: i32 = 0,
    roomWy: i32 = 0,
    terrainIncluded: u32 = 0,
    controllerPresent: u32 = 0,
    spawnCount: u32 = 0,
    sourceCount: u32 = 0,
    creepCount: u32 = 0,
    droppedCount: u32 = 0,
    controller: ControllerRecord = undefined,
    spawns: [spud.MAX_SPAWNS]SpawnRecord = undefined,
    sources: [spud.MAX_SOURCES]SourceRecord = undefined,
    creeps: [spud.MAX_CREEPS]CreepRecord = undefined,
    dropped: [spud.MAX_DROPPED]DroppedRecord = undefined,
    terrain: [spud.TERRAIN_BYTES]u8 = undefined,

    pub const binding = .{
        .args = .{ "tick", "cpuBucket", "roomWx", "roomWy" },
        .sections = .{
            .{ .field = "controller", .count = "controllerPresent" },
            .{ .field = "spawns", .count = "spawnCount" },
            .{ .field = "sources", .count = "sourceCount" },
            .{ .field = "creeps", .count = "creepCount" },
            .{ .field = "dropped", .count = "droppedCount" },
        },
        .terrain = .{ .field = "terrain", .present = "terrainIncluded", .room_size = spud.ROOM_SIZE },
    };
};
/// One command, fixed-size regardless of opcode (unused fields are ignored).
/// The output half of scratchPad is just commandCount(u32) followed by this
/// many records. The binding metadata selects each opcode's callback arguments.
const CommandRecord = extern struct {
    opcode: Opcode,
    role: spud.Role = .none,
    bodyLen: u32 = 0, // spawn only
    direction: u32 = 0, // move only
    amount: u32 = 0, // transfer/withdraw only
    actorHandle: u32 = 0,
    targetHandle: u32 = 0,
    body: [spud.MAX_BODY_PARTS]u8 = std.mem.zeroes([spud.MAX_BODY_PARTS]u8), // spawn only

    pub const binding = .{
        .discriminant = "opcode",
        .callbacks = .{
            .{ .method = "spawn", .args = .{ "actorHandle", "role", "body" } },
            .{ .method = "move", .args = .{ "actorHandle", "direction" } },
            .{ .method = "harvest", .args = .{ "actorHandle", "targetHandle" } },
            .{ .method = "transfer", .args = .{ "actorHandle", "targetHandle", "amount" } },
            .{ .method = "withdraw", .args = .{ "actorHandle", "targetHandle", "amount" } },
            .{ .method = "pickup", .args = .{ "actorHandle", "targetHandle" } },
            .{ .method = "upgrade", .args = .{ "actorHandle", "targetHandle" } },
        },
        .lengths = .{ .body = "bodyLen" },
    };
};
const Opcode = enum(u32) {
    spawn = 1,
    move = 2,
    harvest = 3,
    transfer = 4,
    withdraw = 5,
    pickup = 6,
    upgrade = 7,
};

const binding_source = interop.typescript(World, CommandRecord, spud.Role, spud.Part, INPUT_SIZE, spud.AMOUNT_ALL);

export fn bindingsPtr() [*]const u8 {
    return binding_source.ptr;
}

export fn bindingsLen() u32 {
    return binding_source.len;
}

fn toDomainController(r: ControllerRecord) spud.Controller {
    return .{
        .id = r.id.id,
        .pos = .{ .x = r.pos.x, .y = r.pos.y },
        .level = @intCast(r.level),
        .progress = r.progress,
        .progressTotal = r.progressTotal,
        .owned = r.owned,
    };
}

fn toDomainSpawn(r: SpawnRecord) spud.Spawn {
    return .{
        .id = r.id.id,
        .pos = .{ .x = r.pos.x, .y = r.pos.y },
        .energy = @intCast(r.energy),
        .energyCapacity = @intCast(r.energyCapacity),
        .spawning = r.spawning,
    };
}

fn toDomainSource(r: SourceRecord) spud.Source {
    return .{
        .id = r.id.id,
        .pos = .{ .x = r.pos.x, .y = r.pos.y },
        .energy = @intCast(r.energy),
        .energyCapacity = @intCast(r.energyCapacity),
    };
}

fn toDomainCreep(r: CreepRecord) spud.CreepIn {
    return .{
        .id = r.id.id,
        .pos = .{ .x = r.pos.x, .y = r.pos.y },
        .carry = @intCast(r.carry),
        .carryCapacity = @intCast(r.carryCapacity),
        .role = r.role,
        .workParts = r.workParts,
        .carryParts = r.carryParts,
        .moveParts = r.moveParts,
        .spawning = r.spawning,
    };
}

fn toDomainDropped(r: DroppedRecord) spud.Dropped {
    return .{ .id = r.id.id, .pos = .{ .x = r.pos.x, .y = r.pos.y }, .amount = @intCast(r.amount) };
}

fn decodeInput(world: *const World, spawns: *[spud.MAX_SPAWNS]spud.Spawn, sources: *[spud.MAX_SOURCES]spud.Source, creeps: *[spud.MAX_CREEPS]spud.CreepIn, dropped: *[spud.MAX_DROPPED]spud.Dropped) spud.TickInput {
    for (0..world.spawnCount) |i| spawns[i] = toDomainSpawn(world.spawns[i]);
    for (0..world.sourceCount) |i| sources[i] = toDomainSource(world.sources[i]);
    for (0..world.creepCount) |i| creeps[i] = toDomainCreep(world.creeps[i]);
    for (0..world.droppedCount) |i| dropped[i] = toDomainDropped(world.dropped[i]);

    return .{
        .tick = world.tick,
        .cpuBucket = @intCast(@min(world.cpuBucket, std.math.maxInt(u16))),
        .room = .{ .wx = world.roomWx, .wy = world.roomWy },
        .terrain = if (world.terrainIncluded == 1) &world.terrain else null,
        .controller = if (world.controllerPresent == 1) toDomainController(world.controller) else null,
        .spawns = spawns[0..world.spawnCount],
        .sources = sources[0..world.sourceCount],
        .creeps = creeps[0..world.creepCount],
        .dropped = dropped[0..world.droppedCount],
    };
}

fn resolveHandle(world: *const World, id: ObjectId) u32 {
    if (world.controllerPresent == 1 and std.mem.eql(u8, &world.controller.id.id, &id)) {
        return world.controller.id.handle;
    }
    inline for (.{ .{ "spawns", "spawnCount" }, .{ "sources", "sourceCount" }, .{ "creeps", "creepCount" }, .{ "dropped", "droppedCount" } }) |section| {
        for (@field(world, section[0])[0..@field(world, section[1])]) |record| {
            if (std.mem.eql(u8, &record.id.id, &id)) return record.id.handle;
        }
    }
    return 0;
}

fn encodeCommand(world: *const World, command: spud.Command) CommandRecord {
    return switch (command) {
        .spawn => |c| .{
            .opcode = .spawn,
            .role = c.role,
            .bodyLen = c.bodyLen,
            .actorHandle = resolveHandle(world, c.spawnId),
            .body = blk: {
                var body: [spud.MAX_BODY_PARTS]u8 = std.mem.zeroes([spud.MAX_BODY_PARTS]u8);
                for (c.body[0..c.bodyLen], 0..) |p, i| body[i] = @intFromEnum(p);
                break :blk body;
            },
        },
        .move => |c| .{ .opcode = .move, .actorHandle = resolveHandle(world, c.creepId), .direction = c.direction },
        .harvest => |c| .{ .opcode = .harvest, .actorHandle = resolveHandle(world, c.creepId), .targetHandle = resolveHandle(world, c.targetId) },
        .transfer => |c| .{ .opcode = .transfer, .actorHandle = resolveHandle(world, c.creepId), .targetHandle = resolveHandle(world, c.targetId), .amount = c.amount },
        .withdraw => |c| .{ .opcode = .withdraw, .actorHandle = resolveHandle(world, c.creepId), .targetHandle = resolveHandle(world, c.targetId), .amount = c.amount },
        .pickup => |c| .{ .opcode = .pickup, .actorHandle = resolveHandle(world, c.creepId), .targetHandle = resolveHandle(world, c.targetId) },
        .upgrade => |c| .{ .opcode = .upgrade, .actorHandle = resolveHandle(world, c.creepId), .targetHandle = resolveHandle(world, c.targetId) },
    };
}

/// Shared buffer TS writes the tick snapshot (a World) into and reads
/// commands back from. Split in half: [0, INPUT_SIZE) is input, [INPUT_SIZE,
/// page_size) is output (commandCount: u32, then commandCount CommandRecords).
/// INPUT_SIZE is embedded in the comptime-generated TypeScript binding.
const INPUT_SIZE: u32 = std.wasm.page_size / 2;
var scratchPad: [std.wasm.page_size]u8 align(4) = undefined;

comptime {
    std.debug.assert(@sizeOf(World) <= INPUT_SIZE);
    std.debug.assert(4 + spud.MAX_COMMANDS * @sizeOf(CommandRecord) <= std.wasm.page_size - INPUT_SIZE);
}

/// Returns the linear-memory offset of scratchPad so TS can view it directly
/// via `new Uint8Array(instance.exports.memory.buffer, ptr, size)`.
export fn scratchPtr() [*]u8 {
    return &scratchPad;
}

/// Runs one bot tick: decodes the World TS wrote into scratchPad, asks
/// root.zig what to do, writes its commands back into the output half, and
/// returns the number of bytes written so TS knows how much of it to read.
export fn loop() u32 {
    const world: *const World = @ptrCast(@alignCast(scratchPad[0..].ptr));

    var spawns: [spud.MAX_SPAWNS]spud.Spawn = undefined;
    var sources: [spud.MAX_SOURCES]spud.Source = undefined;
    var creeps: [spud.MAX_CREEPS]spud.CreepIn = undefined;
    var dropped: [spud.MAX_DROPPED]spud.Dropped = undefined;
    const tickInput = decodeInput(world, &spawns, &sources, &creeps, &dropped);

    var commands: [spud.MAX_COMMANDS]spud.Command = undefined;
    const count = spud.tick(tickInput, &commands);

    const commandsOut: [*]CommandRecord = @ptrCast(@alignCast(scratchPad[INPUT_SIZE + 4 ..].ptr));
    for (commands[0..count], 0..) |command, i| commandsOut[i] = encodeCommand(world, command);
    std.mem.writeInt(u32, scratchPad[INPUT_SIZE..][0..4], @intCast(count), .little);

    return @intCast(4 + count * @sizeOf(CommandRecord));
}
