// Wasm boundary: builds a World snapshot of the room each tick, runs Zig's
// loop(), then dispatches the command records it writes back as Screeps API
// calls. The wire format is `extern struct`s memory-mapped directly onto the
// shared scratch buffer - see the doc comment at the top of src/entry.zig for
// the full explanation. Keep the offsets/sizes below in sync with it.
const ID_BYTES = 12
const ROOM_SIZE = 50
const PAGE_SIZE = 65536
const INPUT_SIZE = PAGE_SIZE / 2

// Must match the array capacities in src/root.zig.
const MAX_SPAWNS = 4
const MAX_SOURCES = 8
const MAX_CREEPS = 32
const MAX_DROPPED = 16

// Fixed header field offsets within World: a stable run of u32 fields in
// declaration order (see entry.zig's World doc-comment).
const HEADER_TICK = 0
const HEADER_CPU_BUCKET = 4
const HEADER_ROOM_WX = 8
const HEADER_ROOM_WY = 12
const HEADER_TERRAIN_INCLUDED = 16
const HEADER_CONTROLLER_PRESENT = 20
const HEADER_SPAWN_COUNT = 24
const HEADER_SOURCE_COUNT = 28
const HEADER_CREEP_COUNT = 32
const HEADER_DROPPED_COUNT = 36

// Indices into the layout array returned by layoutPtr() - must match the
// `layout` array in src/entry.zig exactly (order and count).
const enum LayoutIndex {
  WorldSize = 0,
  ControllerOffset = 1,
  ControllerSize = 2,
  SpawnsOffset = 3,
  SpawnSize = 4,
  SourcesOffset = 5,
  SourceSize = 6,
  CreepsOffset = 7,
  CreepSize = 8,
  DroppedOffset = 9,
  DroppedSize = 10,
  TerrainOffset = 11,
  CommandSize = 12,
}
const LAYOUT_LEN = 13

const enum Role {
  None = 0,
  Harvester = 1,
  Hauler = 2,
  Upgrader = 3,
}

const enum Opcode {
  Spawn = 1,
  Move = 2,
  Harvest = 3,
  Transfer = 4,
  Withdraw = 5,
  Pickup = 6,
  Upgrade = 7,
}

const AMOUNT_ALL = 0xffff

const ROLE_NAMES: Record<Role, string> = {
  [Role.None]: "none",
  [Role.Harvester]: "harvester",
  [Role.Hauler]: "hauler",
  [Role.Upgrader]: "upgrader",
}
const ROLE_BY_NAME: Record<string, Role> = {
  harvester: Role.Harvester,
  hauler: Role.Hauler,
  upgrader: Role.Upgrader,
}

// Not a module-level constant: WORK/CARRY/MOVE are Screeps runtime globals
// that don't exist outside the game (e.g. in unit tests), so this must only
// be evaluated lazily, when a command actually needs it.
function partForCode(code: number): BodyPartConstant {
  return [WORK, CARRY, MOVE][code]
}

function roleOf(memory: CreepMemory | undefined): Role {
  return (memory && ROLE_BY_NAME[memory.role]) || Role.None
}

function idToBytes(id: string | undefined, out: Uint8Array, offset: number): void {
  if (id == null) {
    out.fill(0, offset, offset + ID_BYTES)
    return
  }
  for (let i = 0; i < ID_BYTES; i++) {
    out[offset + i] = parseInt(id.substr(i * 2, 2), 16)
  }
}

function idFromBytes(buf: Uint8Array, offset: number): string {
  let s = ""
  for (let i = 0; i < ID_BYTES; i++) {
    s += buf[offset + i].toString(16).padStart(2, "0")
  }
  return s
}

// Same scheme as the Screeps engine's roomNameToXY: signed world coordinates
// instead of the room name string, so nothing string-shaped crosses the wasm
// boundary (see RoomPosition's __packedPos in the engine source).
function roomNameToXY(roomName: string): { wx: number; wy: number } {
  const match = /^([WE])(\d+)([NS])(\d+)$/.exec(roomName)
  if (match == null) throw new Error(`Invalid room name: ${roomName}`)
  const wx = match[1] === "W" ? -parseInt(match[2], 10) - 1 : parseInt(match[2], 10)
  const wy = match[3] === "N" ? -parseInt(match[4], 10) - 1 : parseInt(match[4], 10)
  return { wx, wy }
}

// Field offsets below mirror entry.zig's extern structs field-for-field
// (see its doc comment) - update both together.

// ControllerRecord: level,u32@0 progress,u32@4 progressTotal,u32@8 id,12b@12 x,u8@24 y,u8@25 owned,u8@26
function writeController(
  buf: Uint8Array,
  view: DataView,
  base: number,
  controller: StructureController,
): void {
  view.setUint32(base + 0, controller.level, true)
  view.setUint32(base + 4, controller.progress, true)
  view.setUint32(base + 8, controller.progressTotal, true)
  idToBytes(controller.id, buf, base + 12)
  buf[base + 24] = controller.pos.x
  buf[base + 25] = controller.pos.y
  buf[base + 26] = controller.my ? 1 : 0
}

// SpawnRecord: energy,u32@0 energyCapacity,u32@4 id,12b@8 x,u8@20 y,u8@21 spawning,u8@22
function writeSpawn(buf: Uint8Array, view: DataView, base: number, spawn: StructureSpawn): void {
  view.setUint32(base + 0, spawn.store.getUsedCapacity(RESOURCE_ENERGY), true)
  view.setUint32(base + 4, spawn.store.getCapacity(RESOURCE_ENERGY) ?? 0, true)
  idToBytes(spawn.id, buf, base + 8)
  buf[base + 20] = spawn.pos.x
  buf[base + 21] = spawn.pos.y
  buf[base + 22] = spawn.spawning ? 1 : 0
}

// SourceRecord: energy,u32@0 energyCapacity,u32@4 id,12b@8 x,u8@20 y,u8@21
function writeSource(buf: Uint8Array, view: DataView, base: number, source: Source): void {
  view.setUint32(base + 0, source.energy, true)
  view.setUint32(base + 4, source.energyCapacity, true)
  idToBytes(source.id, buf, base + 8)
  buf[base + 20] = source.pos.x
  buf[base + 21] = source.pos.y
}

// CreepRecord: carry,u32@0 carryCapacity,u32@4 id,12b@8 x,u8@20 y,u8@21 role,u8@22
//              workParts,u8@23 carryParts,u8@24 moveParts,u8@25 spawning,u8@26
function writeCreep(buf: Uint8Array, view: DataView, base: number, creep: Creep): void {
  view.setUint32(base + 0, creep.store.getUsedCapacity(RESOURCE_ENERGY), true)
  view.setUint32(base + 4, creep.store.getCapacity(RESOURCE_ENERGY) ?? 0, true)
  idToBytes(creep.id, buf, base + 8)
  buf[base + 20] = creep.pos.x
  buf[base + 21] = creep.pos.y
  buf[base + 22] = roleOf(creep.memory)
  buf[base + 23] = creep.getActiveBodyparts(WORK)
  buf[base + 24] = creep.getActiveBodyparts(CARRY)
  buf[base + 25] = creep.getActiveBodyparts(MOVE)
  buf[base + 26] = creep.spawning ? 1 : 0
}

// DroppedRecord: amount,u32@0 id,12b@4 x,u8@16 y,u8@17
function writeDropped(buf: Uint8Array, view: DataView, base: number, resource: Resource): void {
  view.setUint32(base + 0, Math.min(resource.amount, 0xffffffff), true)
  idToBytes(resource.id, buf, base + 4)
  buf[base + 16] = resource.pos.x
  buf[base + 17] = resource.pos.y
}

interface WasmExports {
  memory: WebAssembly.Memory
  scratchPtr: () => number
  layoutPtr: () => number
  loop: () => number
}

let exportsCache: WasmExports | undefined
let layoutCache: number[] | undefined
let terrainSent = false

// Screeps binary modules load as a raw ArrayBuffer via require(), no base64
// embedding needed - see https://docs.screeps.com/modules.html#Binary-modules.
// "spud" must be uploaded as a binary module built from zig-out/bin/spud.wasm
// (rolldown.config.ts emits it as an asset alongside main.js).
declare const require: (path: "spud") => ArrayBuffer

/** Lazily instantiates the wasm module (synchronous - the bytes are already local, no fetch involved). */
function getExports(): WasmExports {
  if (exportsCache == null) {
    const module = new WebAssembly.Module(require("spud"))
    const instance = new WebAssembly.Instance(module, {})
    exportsCache = instance.exports as unknown as WasmExports
  }
  return exportsCache
}

function getLayout(exports: WasmExports): number[] {
  if (layoutCache == null) {
    layoutCache = Array.from(
      new Uint32Array(exports.memory.buffer, exports.layoutPtr(), LAYOUT_LEN),
    )
  }
  return layoutCache
}

function findMainRoom(): Room | undefined {
  for (const name in Game.rooms) {
    const room = Game.rooms[name]
    if (room.controller && room.controller.my) return room
  }
  return undefined
}

function writeTerrain(buf: Uint8Array, base: number, room: Room): boolean {
  if (terrainSent) return false

  const terrain = room.getTerrain()
  for (let y = 0; y < ROOM_SIZE; y++) {
    for (let x = 0; x < ROOM_SIZE; x++) {
      if (terrain.get(x, y) === TERRAIN_MASK_WALL) {
        const idx = y * ROOM_SIZE + x
        buf[base + (idx >> 3)] |= 1 << (idx & 7)
      }
    }
  }
  terrainSent = true
  return true
}

function buildSnapshot(buf: Uint8Array, view: DataView, layout: number[], room: Room): void {
  view.setUint32(HEADER_TICK, Game.time, true)
  view.setUint32(HEADER_CPU_BUCKET, Math.max(0, Game.cpu.bucket), true)
  const { wx, wy } = roomNameToXY(room.name)
  view.setInt32(HEADER_ROOM_WX, wx, true)
  view.setInt32(HEADER_ROOM_WY, wy, true)

  const terrainIncluded = writeTerrain(buf, layout[LayoutIndex.TerrainOffset], room)
  view.setUint32(HEADER_TERRAIN_INCLUDED, terrainIncluded ? 1 : 0, true)

  const controller = room.controller
  view.setUint32(HEADER_CONTROLLER_PRESENT, controller ? 1 : 0, true)
  if (controller) writeController(buf, view, layout[LayoutIndex.ControllerOffset], controller)

  const spawns = room.find(FIND_MY_SPAWNS).slice(0, MAX_SPAWNS)
  view.setUint32(HEADER_SPAWN_COUNT, spawns.length, true)
  spawns.forEach((spawn, i) =>
    writeSpawn(
      buf,
      view,
      layout[LayoutIndex.SpawnsOffset] + i * layout[LayoutIndex.SpawnSize],
      spawn,
    ),
  )

  const sources = room.find(FIND_SOURCES).slice(0, MAX_SOURCES)
  view.setUint32(HEADER_SOURCE_COUNT, sources.length, true)
  sources.forEach((source, i) =>
    writeSource(
      buf,
      view,
      layout[LayoutIndex.SourcesOffset] + i * layout[LayoutIndex.SourceSize],
      source,
    ),
  )

  const creeps = room.find(FIND_MY_CREEPS).slice(0, MAX_CREEPS)
  view.setUint32(HEADER_CREEP_COUNT, creeps.length, true)
  creeps.forEach((creep, i) =>
    writeCreep(
      buf,
      view,
      layout[LayoutIndex.CreepsOffset] + i * layout[LayoutIndex.CreepSize],
      creep,
    ),
  )

  const dropped = room
    .find(FIND_DROPPED_RESOURCES, { filter: (r) => r.resourceType === RESOURCE_ENERGY })
    .slice(0, MAX_DROPPED)
  view.setUint32(HEADER_DROPPED_COUNT, dropped.length, true)
  dropped.forEach((resource, i) =>
    writeDropped(
      buf,
      view,
      layout[LayoutIndex.DroppedOffset] + i * layout[LayoutIndex.DroppedSize],
      resource,
    ),
  )
}

// CommandRecord: opcode,u32@0 role,u32@4 bodyLen,u32@8 direction,u32@12 amount,u32@16
//                creepId,12b@20 targetId,12b@32 body,16b@44
function dispatchSpawn(buf: Uint8Array, view: DataView, base: number, room: Room): void {
  const role = view.getUint32(base + 4, true) as Role
  const bodyLen = view.getUint32(base + 8, true)
  const spawnId = idFromBytes(buf, base + 20)

  const body: BodyPartConstant[] = []
  for (let i = 0; i < bodyLen; i++) body.push(partForCode(buf[base + 44 + i]))

  const spawn = Game.getObjectById<StructureSpawn>(spawnId)
  if (spawn == null) return
  const name = `${ROLE_NAMES[role]}_${Game.time}`
  spawn.spawnCreep(body, name, {
    memory: { role: ROLE_NAMES[role], room: room.name, working: false },
  })
}

function dispatchCommands(
  buf: Uint8Array,
  view: DataView,
  commandSize: number,
  count: number,
  room: Room,
): void {
  for (let i = 0; i < count; i++) {
    const base = 4 + i * commandSize
    const opcode = view.getUint32(base + 0, true) as Opcode
    switch (opcode) {
      case Opcode.Spawn:
        dispatchSpawn(buf, view, base, room)
        break
      case Opcode.Move: {
        const creep = Game.getObjectById<Creep>(idFromBytes(buf, base + 20))
        const direction = view.getUint32(base + 12, true) as DirectionConstant
        creep?.move(direction)
        break
      }
      case Opcode.Harvest: {
        const creep = Game.getObjectById<Creep>(idFromBytes(buf, base + 20))
        const target = Game.getObjectById<Source>(idFromBytes(buf, base + 32))
        if (creep && target) creep.harvest(target)
        break
      }
      case Opcode.Transfer: {
        const creep = Game.getObjectById<Creep>(idFromBytes(buf, base + 20))
        const target = Game.getObjectById<AnyCreep | Structure>(idFromBytes(buf, base + 32))
        const amount = view.getUint32(base + 16, true)
        if (creep && target)
          creep.transfer(target, RESOURCE_ENERGY, amount === AMOUNT_ALL ? undefined : amount)
        break
      }
      case Opcode.Withdraw: {
        const creep = Game.getObjectById<Creep>(idFromBytes(buf, base + 20))
        const target = Game.getObjectById<Structure>(idFromBytes(buf, base + 32))
        const amount = view.getUint32(base + 16, true)
        if (creep && target)
          creep.withdraw(target, RESOURCE_ENERGY, amount === AMOUNT_ALL ? undefined : amount)
        break
      }
      case Opcode.Pickup: {
        const creep = Game.getObjectById<Creep>(idFromBytes(buf, base + 20))
        const target = Game.getObjectById<Resource>(idFromBytes(buf, base + 32))
        if (creep && target) creep.pickup(target)
        break
      }
      case Opcode.Upgrade: {
        const creep = Game.getObjectById<Creep>(idFromBytes(buf, base + 20))
        const target = Game.getObjectById<StructureController>(idFromBytes(buf, base + 32))
        if (creep && target) creep.upgradeController(target)
        break
      }
    }
  }
}

/** Builds the tick snapshot, runs the Zig bot logic, and dispatches its commands. Does nothing if there's no owned room yet. */
export function runTick(): void {
  const room = findMainRoom()
  if (room == null) return

  const exports = getExports()
  const layout = getLayout(exports)
  const ptr = exports.scratchPtr()

  const input = new Uint8Array(exports.memory.buffer, ptr, INPUT_SIZE)
  const inputView = new DataView(exports.memory.buffer, ptr, INPUT_SIZE)
  buildSnapshot(input, inputView, layout, room)

  const written = exports.loop()

  const outputPtr = ptr + INPUT_SIZE
  const output = new Uint8Array(exports.memory.buffer, outputPtr, written)
  const outputView = new DataView(exports.memory.buffer, outputPtr, written)
  const commandCount = outputView.getUint32(0, true)
  dispatchCommands(output, outputView, layout[LayoutIndex.CommandSize], commandCount, room)
}
