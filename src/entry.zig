const std = @import("std");
const builtin = @import("builtin");
const spud = @import("spud");

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
// The wire format is a set of `extern struct`s (C ABI, no padding surprises
// as long as fields are ordered largest-alignment-first - enforced by the
// size asserts below) memory-mapped directly onto the shared scratch buffer,
// instead of a hand-rolled sequential reader/writer. TS can't see Zig's
// `extern struct` layout, so `layoutPtr()` exports the handful of offsets and
// strides that depend on nested-struct padding (everything else - header
// field offsets, array capacities - is a small fixed set of numbers
// documented in comments below and mirrored by hand in src/binding.ts).

const ObjectId = spud.ObjectId;

const ControllerRecord = extern struct {
    level: u32,
    progress: u32,
    progressTotal: u32,
    id: ObjectId,
    x: u8,
    y: u8,
    owned: u8,
    _pad: u8 = 0,
};
comptime {
    std.debug.assert(@sizeOf(ControllerRecord) == 28);
}

const SpawnRecord = extern struct {
    energy: u32,
    energyCapacity: u32,
    id: ObjectId,
    x: u8,
    y: u8,
    spawning: u8,
    _pad: u8 = 0,
};
comptime {
    std.debug.assert(@sizeOf(SpawnRecord) == 24);
}

const SourceRecord = extern struct {
    energy: u32,
    energyCapacity: u32,
    id: ObjectId,
    x: u8,
    y: u8,
    _pad: u16 = 0,
};
comptime {
    std.debug.assert(@sizeOf(SourceRecord) == 24);
}

const CreepRecord = extern struct {
    carry: u32,
    carryCapacity: u32,
    id: ObjectId,
    x: u8,
    y: u8,
    role: u8,
    workParts: u8,
    carryParts: u8,
    moveParts: u8,
    spawning: u8,
    _pad: u8 = 0,
};
comptime {
    std.debug.assert(@sizeOf(CreepRecord) == 28);
}

const DroppedRecord = extern struct {
    amount: u32,
    id: ObjectId,
    x: u8,
    y: u8,
    _pad: u16 = 0,
};
comptime {
    std.debug.assert(@sizeOf(DroppedRecord) == 20);
}

/// The full tick snapshot, memory-mapped directly onto the input half of
/// scratchPad. Header fields are a fixed run of u32s (offsets 0, 4, 8, ... -
/// guaranteed stable by Zig's declaration-order layout for extern structs),
/// mirrored by hand as HEADER_* offsets in src/binding.ts. The nested
/// sections' offsets/strides are read from layoutPtr() instead, since they
/// depend on this struct's internal padding.
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
};
comptime {
    std.debug.assert(@offsetOf(World, "cpuBucket") == 4); // sanity check for the header offsets, see doc-comment above
    std.debug.assert(@offsetOf(World, "droppedCount") == 36);
}

/// One command, fixed-size regardless of opcode (unused fields are ignored).
/// The output half of scratchPad is just commandCount(u32) followed by this
/// many records, back to back - no header/nesting, so no padding surprises;
/// TS only needs commandRecordSize() from the layout table to index it.
const CommandRecord = extern struct {
    opcode: u32,
    role: u32 = 0, // spawn only
    bodyLen: u32 = 0, // spawn only
    direction: u32 = 0, // move only
    amount: u32 = 0, // transfer/withdraw only
    creepId: ObjectId = std.mem.zeroes(ObjectId), // acting creep, or spawn id for the spawn command
    targetId: ObjectId = std.mem.zeroes(ObjectId),
    body: [spud.MAX_BODY_PARTS]u8 = std.mem.zeroes([spud.MAX_BODY_PARTS]u8), // spawn only
};
comptime {
    std.debug.assert(@sizeOf(CommandRecord) == 60);
}

const Opcode = enum(u32) {
    spawn = 1,
    move = 2,
    harvest = 3,
    transfer = 4,
    withdraw = 5,
    pickup = 6,
    upgrade = 7,
};

// Layout table: the handful of offsets/sizes that depend on extern struct
// padding, computed by the compiler and exposed via layoutPtr() so TS never
// has to hand-compute (and risk getting wrong) anything but the fixed header
// field offsets. Keep this array and the LayoutIndex enum in src/binding.ts
// in the same order.
const layout: [13]u32 = .{
    @sizeOf(World),
    @offsetOf(World, "controller"),
    @sizeOf(ControllerRecord),
    @offsetOf(World, "spawns"),
    @sizeOf(SpawnRecord),
    @offsetOf(World, "sources"),
    @sizeOf(SourceRecord),
    @offsetOf(World, "creeps"),
    @sizeOf(CreepRecord),
    @offsetOf(World, "dropped"),
    @sizeOf(DroppedRecord),
    @offsetOf(World, "terrain"),
    @sizeOf(CommandRecord),
};

export fn layoutPtr() [*]const u32 {
    return &layout;
}

fn toDomainController(r: ControllerRecord) spud.Controller {
    return .{
        .id = r.id,
        .pos = .{ .x = r.x, .y = r.y },
        .level = @intCast(r.level),
        .progress = r.progress,
        .progressTotal = r.progressTotal,
        .owned = r.owned == 1,
    };
}

fn toDomainSpawn(r: SpawnRecord) spud.Spawn {
    return .{
        .id = r.id,
        .pos = .{ .x = r.x, .y = r.y },
        .energy = @intCast(r.energy),
        .energyCapacity = @intCast(r.energyCapacity),
        .spawning = r.spawning == 1,
    };
}

fn toDomainSource(r: SourceRecord) spud.Source {
    return .{
        .id = r.id,
        .pos = .{ .x = r.x, .y = r.y },
        .energy = @intCast(r.energy),
        .energyCapacity = @intCast(r.energyCapacity),
    };
}

fn toDomainCreep(r: CreepRecord) spud.CreepIn {
    return .{
        .id = r.id,
        .pos = .{ .x = r.x, .y = r.y },
        .carry = @intCast(r.carry),
        .carryCapacity = @intCast(r.carryCapacity),
        .role = @enumFromInt(r.role),
        .workParts = r.workParts,
        .carryParts = r.carryParts,
        .moveParts = r.moveParts,
        .spawning = r.spawning == 1,
    };
}

fn toDomainDropped(r: DroppedRecord) spud.Dropped {
    return .{ .id = r.id, .pos = .{ .x = r.x, .y = r.y }, .amount = @intCast(r.amount) };
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

fn encodeCommand(command: spud.Command) CommandRecord {
    return switch (command) {
        .spawn => |c| .{
            .opcode = @intFromEnum(Opcode.spawn),
            .role = @intFromEnum(c.role),
            .bodyLen = c.bodyLen,
            .creepId = c.spawnId,
            .body = blk: {
                var body: [spud.MAX_BODY_PARTS]u8 = std.mem.zeroes([spud.MAX_BODY_PARTS]u8);
                for (c.body[0..c.bodyLen], 0..) |p, i| body[i] = @intFromEnum(p);
                break :blk body;
            },
        },
        .move => |c| .{ .opcode = @intFromEnum(Opcode.move), .creepId = c.creepId, .direction = c.direction },
        .harvest => |c| .{ .opcode = @intFromEnum(Opcode.harvest), .creepId = c.creepId, .targetId = c.targetId },
        .transfer => |c| .{ .opcode = @intFromEnum(Opcode.transfer), .creepId = c.creepId, .targetId = c.targetId, .amount = c.amount },
        .withdraw => |c| .{ .opcode = @intFromEnum(Opcode.withdraw), .creepId = c.creepId, .targetId = c.targetId, .amount = c.amount },
        .pickup => |c| .{ .opcode = @intFromEnum(Opcode.pickup), .creepId = c.creepId, .targetId = c.targetId },
        .upgrade => |c| .{ .opcode = @intFromEnum(Opcode.upgrade), .creepId = c.creepId, .targetId = c.targetId },
    };
}

/// Shared buffer TS writes the tick snapshot (a World) into and reads
/// commands back from. Split in half: [0, INPUT_SIZE) is input, [INPUT_SIZE,
/// page_size) is output (commandCount: u32, then commandCount CommandRecords).
/// Keep INPUT_SIZE in sync with src/binding.ts.
const INPUT_SIZE: u32 = std.wasm.page_size / 2;
var scratchPad: [std.wasm.page_size]u8 align(4) = undefined;

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
    for (commands[0..count], 0..) |command, i| commandsOut[i] = encodeCommand(command);
    std.mem.writeInt(u32, scratchPad[INPUT_SIZE..][0..4], @intCast(count), .little);

    return @intCast(4 + count * @sizeOf(CommandRecord));
}
