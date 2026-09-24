//! By convention, root.zig is the root source file when making a package.
//!
//! This is the game library: it operates purely on structured Zig types
//! (TickInput in, a list of Command out) and knows nothing about wasm, the
//! shared scratch buffer, or byte layout - that's entry.zig's job.
const std = @import("std");

pub const ROOM_SIZE: usize = 50;
pub const TILE_COUNT: usize = ROOM_SIZE * ROOM_SIZE;
pub const TERRAIN_BYTES: usize = (TILE_COUNT + 7) / 8;

// Shared capacities: entry.zig sizes its wire-decoding buffers off these too.
pub const MAX_SPAWNS = 4;
pub const MAX_SOURCES = 8;
pub const MAX_CREEPS = 32;
pub const MAX_DROPPED = 16;
pub const MAX_BODY_PARTS = 16;
pub const MAX_COMMANDS = MAX_CREEPS + 1; // at most one action per creep, plus one spawn
const MAX_PATH = 50;

pub const Role = enum(u8) {
    none = 0,
    harvester = 1,
    hauler = 2,
    upgrader = 3,
};

pub const Part = enum(u8) {
    work = 0,
    carry = 1,
    move = 2,
};

pub const AMOUNT_ALL: u16 = 0xFFFF;

pub const ObjectId = [12]u8;

fn idEql(a: ObjectId, b: ObjectId) bool {
    return std.mem.eql(u8, &a, &b);
}

/// World-coordinates of a room (e.g. "W5N8"), used instead of the room name
/// string to keep everything at the wasm boundary numeric.
pub const RoomXY = struct {
    wx: i32,
    wy: i32,
};

pub const Pos = struct {
    x: u8,
    y: u8,

    fn eql(self: Pos, other: Pos) bool {
        return self.x == other.x and self.y == other.y;
    }

    fn inRange(self: Pos, other: Pos, range: u8) bool {
        const dx = if (self.x > other.x) self.x - other.x else other.x - self.x;
        const dy = if (self.y > other.y) self.y - other.y else other.y - self.y;
        return dx <= range and dy <= range;
    }
};

pub const Controller = struct {
    id: ObjectId,
    pos: Pos,
    level: u8,
    progress: u32,
    progressTotal: u32,
    owned: bool,
};

pub const Spawn = struct {
    id: ObjectId,
    pos: Pos,
    energy: u16,
    energyCapacity: u16,
    spawning: bool,
};

pub const Source = struct {
    id: ObjectId,
    pos: Pos,
    energy: u16,
    energyCapacity: u16,
};

pub const Dropped = struct {
    id: ObjectId,
    pos: Pos,
    amount: u16,
};

pub const CreepIn = struct {
    id: ObjectId,
    pos: Pos,
    carry: u16,
    carryCapacity: u16,
    role: Role,
    workParts: u8,
    carryParts: u8,
    moveParts: u8,
    spawning: bool,
};

/// Structured, already-decoded tick snapshot (entry.zig builds this from the
/// wire buffer).
pub const TickInput = struct {
    tick: u32 = 0,
    cpuBucket: u16 = 0,
    room: RoomXY = .{ .wx = 0, .wy = 0 },
    terrain: ?[]const u8 = null, // TERRAIN_BYTES long when present
    controller: ?Controller = null,
    spawns: []const Spawn = &.{},
    sources: []const Source = &.{},
    creeps: []const CreepIn = &.{},
    dropped: []const Dropped = &.{},
};

/// A single bot action. entry.zig serializes these to the output wire format.
pub const Command = union(enum) {
    spawn: struct { spawnId: ObjectId, role: Role, body: [MAX_BODY_PARTS]Part, bodyLen: u8 },
    move: struct { creepId: ObjectId, direction: u8 },
    harvest: struct { creepId: ObjectId, targetId: ObjectId },
    transfer: struct { creepId: ObjectId, targetId: ObjectId, amount: u16 },
    withdraw: struct { creepId: ObjectId, targetId: ObjectId, amount: u16 },
    pickup: struct { creepId: ObjectId, targetId: ObjectId },
    upgrade: struct { creepId: ObjectId, targetId: ObjectId },
};

/// Persistent (across ticks, best-effort) per-creep pathing/assignment state.
const Tracked = struct {
    id: ObjectId = std.mem.zeroes(ObjectId),
    used: bool = false,
    role: Role = .none,
    assignedSource: ObjectId = std.mem.zeroes(ObjectId),
    hasAssignedSource: bool = false,
    pathTarget: Pos = .{ .x = 0, .y = 0 },
    hasPathTarget: bool = false,
    path: [MAX_PATH]u8 = undefined,
    pathLen: u8 = 0,
    pathIdx: u8 = 0,
};

// --- persistent module state -------------------------------------------------

var terrain: [TERRAIN_BYTES]u8 = std.mem.zeroes([TERRAIN_BYTES]u8);
var hasTerrain: bool = false;
var tracked: [MAX_CREEPS]Tracked = undefined;

fn setBlocked(blocked: *[TERRAIN_BYTES]u8, x: u8, y: u8) void {
    const idx = @as(usize, y) * ROOM_SIZE + @as(usize, x);
    blocked[idx / 8] |= (@as(u8, 1) << @intCast(idx % 8));
}

fn isBlocked(blocked: *const [TERRAIN_BYTES]u8, x: u8, y: u8) bool {
    const idx = @as(usize, y) * ROOM_SIZE + @as(usize, x);
    return (blocked[idx / 8] & (@as(u8, 1) << @intCast(idx % 8))) != 0;
}

// Screeps direction constants: TOP=1 .. TOP_LEFT=8, clockwise.
const DX = [8]i16{ 0, 1, 1, 1, 0, -1, -1, -1 };
const DY = [8]i16{ -1, -1, 0, 1, 1, 1, 1, 0 };

/// Breadth-first search over the (unweighted) walkable grid. Swamp cost is
/// ignored for this MVP - only walls/structures/sources/controller block.
/// Returns the path as a sequence of Screeps direction codes (1-8), or an
/// empty slice if no path was found.
fn findPath(blocked: *const [TERRAIN_BYTES]u8, from: Pos, to: Pos, range: u8, out: *[MAX_PATH]u8) u8 {
    if (from.inRange(to, range)) return 0;

    var cameFrom: [TILE_COUNT]i16 = undefined; // -1 = unvisited, else direction index (0-7) taken to reach it
    @memset(&cameFrom, -1);
    var queue: [TILE_COUNT]u16 = undefined;
    var qHead: usize = 0;
    var qTail: usize = 0;

    const startIdx: u16 = @intCast(@as(usize, from.y) * ROOM_SIZE + from.x);
    cameFrom[startIdx] = -2; // mark start as visited, no direction
    queue[qTail] = startIdx;
    qTail += 1;

    var foundIdx: ?u16 = null;
    while (qHead < qTail) {
        const cur = queue[qHead];
        qHead += 1;
        const cx: u8 = @intCast(cur % ROOM_SIZE);
        const cy: u8 = @intCast(cur / ROOM_SIZE);

        if (Pos.inRange(.{ .x = cx, .y = cy }, to, range)) {
            foundIdx = cur;
            break;
        }

        for (0..8) |dir| {
            const nx = @as(i16, cx) + DX[dir];
            const ny = @as(i16, cy) + DY[dir];
            if (nx < 0 or ny < 0 or nx >= ROOM_SIZE or ny >= ROOM_SIZE) continue;
            const ux: u8 = @intCast(nx);
            const uy: u8 = @intCast(ny);
            if (isBlocked(blocked, ux, uy)) continue;
            const nIdx: u16 = @intCast(@as(usize, uy) * ROOM_SIZE + ux);
            if (cameFrom[nIdx] != -1) continue;
            cameFrom[nIdx] = @intCast(dir);
            queue[qTail] = nIdx;
            qTail += 1;
        }
    }

    const target = foundIdx orelse return 0;
    // Walk back from target to start, collecting directions, then reverse.
    var rev: [MAX_PATH]u8 = undefined;
    var len: u8 = 0;
    var cur = target;
    while (cameFrom[cur] != -2 and len < MAX_PATH) {
        const dir: u8 = @intCast(cameFrom[cur]);
        rev[len] = dir + 1; // Screeps directions are 1-based
        len += 1;
        const cx: u8 = @intCast(cur % ROOM_SIZE);
        const cy: u8 = @intCast(cur / ROOM_SIZE);
        const bx = @as(i16, cx) - DX[dir];
        const by = @as(i16, cy) - DY[dir];
        cur = @intCast(@as(usize, @as(u8, @intCast(by))) * ROOM_SIZE + @as(u8, @intCast(bx)));
    }
    var i: u8 = 0;
    while (i < len) : (i += 1) {
        out[i] = rev[len - 1 - i];
    }
    return len;
}

fn findTracked(id: ObjectId) ?*Tracked {
    for (&tracked) |*t| {
        if (t.used and idEql(t.id, id)) return t;
    }
    return null;
}

fn allocTracked(id: ObjectId) ?*Tracked {
    for (&tracked) |*t| {
        if (!t.used) {
            t.* = .{ .id = id, .used = true };
            return t;
        }
    }
    return null;
}

/// Move `t` towards `target` (within `range` tiles), (re)computing its cached
/// BFS path if the target moved or the path was exhausted. Returns a
/// direction to move this tick, or null if already in range / no path.
fn stepTowards(t: *Tracked, blocked: *const [TERRAIN_BYTES]u8, from: Pos, target: Pos, range: u8) ?u8 {
    if (from.inRange(target, range)) return null;

    const needsRecompute = !t.hasPathTarget or !t.pathTarget.eql(target) or t.pathIdx >= t.pathLen;
    if (needsRecompute) {
        t.pathLen = findPath(blocked, from, target, range, &t.path);
        t.pathIdx = 0;
        t.pathTarget = target;
        t.hasPathTarget = true;
        if (t.pathLen == 0) return null;
    }
    if (t.pathIdx >= t.pathLen) return null;
    const dir = t.path[t.pathIdx];
    t.pathIdx += 1;
    return dir;
}

fn countByRole(creeps: []const CreepIn, role: Role) u16 {
    var n: u16 = 0;
    for (creeps) |c| {
        if (c.role == role) n += 1;
    }
    return n;
}

/// Choose a body for `role` scaled to the given energy budget. Returns the
/// number of parts written into `out`.
fn planBody(role: Role, capacity: u16, out: *[MAX_BODY_PARTS]Part) u8 {
    var len: u8 = 0;
    switch (role) {
        .harvester => {
            const workCount = std.math.clamp(capacity / 100, 1, 5);
            var i: u16 = 0;
            while (i < workCount) : (i += 1) {
                out[len] = .work;
                len += 1;
            }
            out[len] = .move;
            len += 1;
        },
        .hauler => {
            const pairs = std.math.clamp(capacity / 100, 1, 8);
            var i: u16 = 0;
            while (i < pairs) : (i += 1) {
                out[len] = .carry;
                len += 1;
                out[len] = .move;
                len += 1;
            }
        },
        .upgrader => {
            const sets = std.math.clamp(capacity / 200, 1, 5);
            var i: u16 = 0;
            while (i < sets) : (i += 1) {
                out[len] = .work;
                len += 1;
                out[len] = .carry;
                len += 1;
                out[len] = .move;
                len += 1;
            }
        },
        .none => {},
    }
    return len;
}

/// Runs one bot tick against the given (already-decoded) snapshot, appending
/// actions to `commands`. Returns the number of commands written.
pub fn tick(input: TickInput, commands: []Command) usize {
    if (input.terrain) |t| {
        @memcpy(&terrain, t);
        hasTerrain = true;
    }

    const creepList = input.creeps;
    const sourceList = input.sources;
    const spawnList = input.spawns;
    const droppedList = input.dropped;

    // Drop tracked entries for creeps that no longer exist.
    for (&tracked) |*t| {
        if (!t.used) continue;
        var stillAlive = false;
        for (creepList) |c| {
            if (idEql(c.id, t.id)) {
                stillAlive = true;
                break;
            }
        }
        if (!stillAlive) t.* = .{};
    }

    // Build the per-tile blocked grid: static terrain plus sources/controller/spawns.
    var blocked: [TERRAIN_BYTES]u8 = std.mem.zeroes([TERRAIN_BYTES]u8);
    if (hasTerrain) @memcpy(&blocked, &terrain);
    for (sourceList) |s| setBlocked(&blocked, s.pos.x, s.pos.y);
    if (input.controller) |c| setBlocked(&blocked, c.pos.x, c.pos.y);
    for (spawnList) |s| setBlocked(&blocked, s.pos.x, s.pos.y);

    var count: usize = 0;

    // --- role assignment for creeps without one yet (fallback path only;
    // normally role is decided at spawn time and persisted in creep memory) ---
    for (creepList) |c| {
        if (c.role != .none) continue;
        const t = findTracked(c.id) orelse allocTracked(c.id) orelse continue;
        if (t.role == .none) {
            const harvesterCount = countByRole(creepList, .harvester);
            if (harvesterCount < sourceList.len) {
                t.role = .harvester;
            } else if (countByRole(creepList, .hauler) < 1) {
                t.role = .hauler;
            } else {
                t.role = .upgrader;
            }
        }
    }

    // --- spawning ---
    if (spawnList.len > 0 and !spawnList[0].spawning) {
        const spawn = spawnList[0];
        const harvesterCount = countByRole(creepList, .harvester);
        const haulerCount = countByRole(creepList, .hauler);
        const upgraderCount = countByRole(creepList, .upgrader);

        var wantRole: ?Role = null;
        if (harvesterCount < sourceList.len) {
            wantRole = .harvester;
        } else if (haulerCount < 1) {
            wantRole = .hauler;
        } else if (upgraderCount < 1) {
            wantRole = .upgrader;
        }

        if (wantRole) |role| {
            var body: [MAX_BODY_PARTS]Part = undefined;
            const bodyLen = planBody(role, spawn.energyCapacity, &body);
            const cost: u16 = blk: {
                var total: u16 = 0;
                for (body[0..bodyLen]) |p| {
                    total += switch (p) {
                        .work => 100,
                        .carry => 50,
                        .move => 50,
                    };
                }
                break :blk total;
            };
            if (cost <= spawn.energy and count < commands.len) {
                commands[count] = .{ .spawn = .{ .spawnId = spawn.id, .role = role, .body = body, .bodyLen = bodyLen } };
                count += 1;
            }
        }
    }

    // --- per-creep behavior ---
    for (creepList) |c| {
        if (c.spawning) continue;
        if (count >= commands.len) break;
        const t = findTracked(c.id) orelse allocTracked(c.id) orelse continue;
        const role = if (c.role != .none) c.role else t.role;
        t.role = role;

        switch (role) {
            .harvester => harvesterTick(commands, &count, t, c, sourceList, &blocked),
            .hauler => haulerTick(commands, &count, t, c, spawnList, droppedList, &blocked),
            .upgrader => upgraderTick(commands, &count, t, c, spawnList, input.controller, &blocked),
            .none => {},
        }
    }

    return count;
}

fn harvesterTick(commands: []Command, count: *usize, t: *Tracked, c: CreepIn, sources: []const Source, blocked: *const [TERRAIN_BYTES]u8) void {
    if (sources.len == 0) return;

    if (!t.hasAssignedSource) {
        // Simple static assignment: pick the source least claimed by other tracked harvesters.
        var best: usize = 0;
        var bestClaims: u32 = std.math.maxInt(u32);
        for (sources, 0..) |s, i| {
            var claims: u32 = 0;
            for (&tracked) |*other| {
                if (other.used and other.role == .harvester and other.hasAssignedSource and idEql(other.assignedSource, s.id)) claims += 1;
            }
            if (claims < bestClaims) {
                bestClaims = claims;
                best = i;
            }
        }
        t.assignedSource = sources[best].id;
        t.hasAssignedSource = true;
    }

    var source: ?Source = null;
    for (sources) |s| {
        if (idEql(s.id, t.assignedSource)) {
            source = s;
            break;
        }
    }
    const src = source orelse sources[0];

    if (stepTowards(t, blocked, c.pos, src.pos, 1)) |dir| {
        emitMove(commands, count, c.id, dir);
    } else {
        emitTargeted(commands, count, .{ .harvest = .{ .creepId = c.id, .targetId = src.id } });
    }
}

fn haulerTick(commands: []Command, count: *usize, t: *Tracked, c: CreepIn, spawns: []const Spawn, dropped: []const Dropped, blocked: *const [TERRAIN_BYTES]u8) void {
    if (c.carry == 0) {
        // find nearest dropped resource
        var best: ?Dropped = null;
        var bestDist: u16 = std.math.maxInt(u16);
        for (dropped) |d| {
            const dx: u16 = if (d.pos.x > c.pos.x) d.pos.x - c.pos.x else c.pos.x - d.pos.x;
            const dy: u16 = if (d.pos.y > c.pos.y) d.pos.y - c.pos.y else c.pos.y - d.pos.y;
            const dist = dx + dy;
            if (dist < bestDist) {
                bestDist = dist;
                best = d;
            }
        }
        if (best) |d| {
            if (stepTowards(t, blocked, c.pos, d.pos, 1)) |dir| {
                emitMove(commands, count, c.id, dir);
            } else {
                emitTargeted(commands, count, .{ .pickup = .{ .creepId = c.id, .targetId = d.id } });
            }
        }
        // no dropped energy available: idle in place this tick
        return;
    }

    if (spawns.len == 0) return;
    const spawn = spawns[0];
    if (spawn.energy >= spawn.energyCapacity) return; // spawn full, nothing to deliver right now
    if (stepTowards(t, blocked, c.pos, spawn.pos, 1)) |dir| {
        emitMove(commands, count, c.id, dir);
    } else {
        emitTargeted(commands, count, .{ .transfer = .{ .creepId = c.id, .targetId = spawn.id, .amount = AMOUNT_ALL } });
    }
}

fn upgraderTick(commands: []Command, count: *usize, t: *Tracked, c: CreepIn, spawns: []const Spawn, controller: ?Controller, blocked: *const [TERRAIN_BYTES]u8) void {
    const ctrl = controller orelse return;

    if (c.carry == 0) {
        if (spawns.len == 0) return;
        const spawn = spawns[0];
        if (spawn.energy == 0) return; // wait for energy
        if (stepTowards(t, blocked, c.pos, spawn.pos, 1)) |dir| {
            emitMove(commands, count, c.id, dir);
        } else {
            emitTargeted(commands, count, .{ .withdraw = .{ .creepId = c.id, .targetId = spawn.id, .amount = AMOUNT_ALL } });
        }
        return;
    }

    if (stepTowards(t, blocked, c.pos, ctrl.pos, 3)) |dir| {
        emitMove(commands, count, c.id, dir);
    } else {
        emitTargeted(commands, count, .{ .upgrade = .{ .creepId = c.id, .targetId = ctrl.id } });
    }
}

fn emitMove(commands: []Command, count: *usize, creepId: ObjectId, dir: u8) void {
    if (count.* >= commands.len) return;
    commands[count.*] = .{ .move = .{ .creepId = creepId, .direction = dir } };
    count.* += 1;
}

fn emitTargeted(commands: []Command, count: *usize, command: Command) void {
    if (count.* >= commands.len) return;
    commands[count.*] = command;
    count.* += 1;
}

test "basic tick with no input produces no commands" {
    for (&tracked) |*t| t.* = .{};
    var commands: [MAX_COMMANDS]Command = undefined;
    const written = tick(.{}, &commands);
    try std.testing.expect(written == 0);
}

test "findPath finds a straight line on an empty grid" {
    var blocked: [TERRAIN_BYTES]u8 = std.mem.zeroes([TERRAIN_BYTES]u8);
    var out: [MAX_PATH]u8 = undefined;
    const len = findPath(&blocked, .{ .x = 0, .y = 0 }, .{ .x = 3, .y = 0 }, 0, &out);
    try std.testing.expect(len == 3);
    for (out[0..len]) |d| try std.testing.expect(d == 3); // RIGHT
}

test "findPath returns 0 when already in range" {
    var blocked: [TERRAIN_BYTES]u8 = std.mem.zeroes([TERRAIN_BYTES]u8);
    var out: [MAX_PATH]u8 = undefined;
    const len = findPath(&blocked, .{ .x = 5, .y = 5 }, .{ .x = 5, .y = 5 }, 0, &out);
    try std.testing.expect(len == 0);
}
