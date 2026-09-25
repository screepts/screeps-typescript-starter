import { execFileSync, spawnSync } from "node:child_process"
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"
import { compileFunction } from "node:vm"
import { ModuleKind, ScriptTarget, transpileModule } from "typescript"
import { afterEach, beforeAll, expect, it, vi } from "vitest"
import type { CommandSink } from "../../src/bindings.generated"

const INPUT_SIZE = 32768

beforeAll(() => {
  execFileSync("zig", ["build"], { cwd: new URL("../../", import.meta.url) })
}, 60_000)

afterEach(() => {
  vi.unstubAllGlobals()
})

function loadGenerated() {
  const generated = {} as typeof import("../../src/bindings.generated")
  const generatedSource = readFileSync(
    new URL("../../src/bindings.generated.ts", import.meta.url),
    "utf8",
  )
  compileFunction(
    transpileModule(generatedSource, {
      compilerOptions: { module: ModuleKind.CommonJS, target: ScriptTarget.ES2024 },
    }).outputText,
    ["exports"],
  )(generated)
  return generated
}

function wasmFixture() {
  const wasm = readFileSync(new URL("../../zig-out/bin/spud.wasm", import.meta.url))
  const instance = new WebAssembly.Instance(new WebAssembly.Module(wasm), {})
  const exports = instance.exports as {
    memory: WebAssembly.Memory & { grow: (pages: number) => number }
    scratchPtr: () => number
    bindingsPtr: () => number
    bindingsLen: () => number
  }
  const source = new TextDecoder().decode(
    new Uint8Array(exports.memory.buffer, exports.bindingsPtr(), exports.bindingsLen()),
  )
  return { ...exports, source }
}

it("resolves current-tick string handles while preserving canonical source assignments", () => {
  const wasm = readFileSync(new URL("../../zig-out/bin/spud.wasm", import.meta.url))
  const generated = loadGenerated()
  const requireWasm = (name: string) => {
    if (name === "./bindings.generated") return generated
    expect(name).toBe("spud")
    return wasm
  }
  for (const name of [
    "WORK",
    "CARRY",
    "MOVE",
    "RESOURCE_ENERGY",
    "FIND_MY_SPAWNS",
    "FIND_SOURCES",
    "FIND_MY_CREEPS",
    "FIND_DROPPED_RESOURCES",
  ]) {
    vi.stubGlobal(name, name)
  }
  vi.stubGlobal("TERRAIN_MASK_WALL", 1)

  const source = {
    id: "1234567890abcdef12345678",
    pos: { x: 11, y: 10 },
    energy: 3000,
    energyCapacity: 3000,
  }
  const otherSource = { ...source, id: "abcdef1234567890abcdef12", pos: { x: 10, y: 11 } }
  const spawn = {
    id: "9876543210abcdef12345678",
    pos: { x: 20, y: 20 },
    store: { getUsedCapacity: () => 250, getCapacity: () => 250 },
    spawnCreep: vi.fn(),
    spawning: null,
  }
  const creep = {
    id: "fedcba987654321001234567",
    pos: { x: 10, y: 10 },
    memory: { role: "harvester" },
    store: { getUsedCapacity: () => 0, getCapacity: () => 50 },
    getActiveBodyparts: () => 1,
    harvest: vi.fn(),
    spawning: false,
  }
  const controller = {
    id: "000000000000000000000001",
    pos: { x: 25, y: 25 },
    my: true,
    level: 1,
    progress: 0,
    progressTotal: 200,
  }
  const collections = {
    FIND_MY_SPAWNS: [spawn],
    FIND_SOURCES: [source, otherSource],
    FIND_MY_CREEPS: [creep],
    FIND_DROPPED_RESOURCES: [],
  }
  const objects = new Map<string, unknown>()
  const game = {
    time: 1,
    cpu: { bucket: 10000 },
    rooms: {
      W0N0: {
        name: "W0N0",
        controller,
        getTerrain: () => ({ get: () => 0 }),
        find: (kind: keyof typeof collections) => collections[kind],
      },
    },
    getObjectById: vi.fn((id: string) => objects.get(id) ?? null),
  }
  vi.stubGlobal("Game", game)
  for (const object of [controller, spawn, source, otherSource, creep]) {
    objects.set(object.id, object)
  }

  const sourceText = readFileSync(new URL("../../src/binding.ts", import.meta.url), "utf8")
  const compiled = transpileModule(sourceText, {
    compilerOptions: { module: ModuleKind.CommonJS, target: ScriptTarget.ES2024 },
  })
  const binding = {} as typeof import("../../src/binding")
  compileFunction(compiled.outputText, ["require", "exports"])(requireWasm, binding)
  const { runTick } = binding
  runTick()
  expect(creep.harvest).toHaveBeenCalledExactlyOnceWith(source)
  expect(spawn.spawnCreep).toHaveBeenCalledWith(["WORK", "WORK", "MOVE"], "harvester_1", {
    memory: { role: "harvester", room: "W0N0", working: false },
  })

  const currentSource = { ...source }
  const currentCreep = { ...creep, harvest: vi.fn() }
  const currentSpawn = { ...spawn, spawnCreep: vi.fn() }
  collections.FIND_SOURCES = [otherSource, currentSource]
  collections.FIND_MY_SPAWNS = [currentSpawn]
  collections.FIND_MY_CREEPS = [currentCreep]
  for (const object of [currentSource, currentCreep, currentSpawn]) {
    objects.set(object.id, object)
  }
  game.time++
  runTick()

  expect(currentCreep.harvest).toHaveBeenCalledExactlyOnceWith(currentSource)
  expect(creep.harvest).toHaveBeenCalledTimes(1)
  expect(currentSpawn.spawnCreep).toHaveBeenCalledTimes(1)
  expect(spawn.spawnCreep).toHaveBeenCalledTimes(1)
})

it("preserves the wire layout and capacities, resets counts, and refreshes grown memory", () => {
  const { memory, scratchPtr } = wasmFixture()
  const { WorldWriter } = loadGenerated()
  const ptr = scratchPtr()
  const writer = new WorldWriter(memory, ptr)
  const id = "1234567890abcdef12345678" as Id<StructureSpawn>
  const position = { x: 17, y: 29 } as RoomPosition
  writer.beginTick(42, 10000, -12, 34)
  for (let index = 0; index < 4; index++) {
    expect(writer.writeSpawn(id, position, 123, 300, true)).toBe(true)
  }
  expect(writer.writeSpawn(id, position, 999, 999, false)).toBe(false)
  let view = new DataView(memory.buffer, ptr, INPUT_SIZE)
  expect(view.getUint32(24, true)).toBe(4)
  expect(view.getInt32(8, true)).toBe(-12)
  expect(view.getUint32(72, true)).toBe(123)
  expect(view.getUint8(72 + 24)).toBe(17)
  expect(view.getUint8(72 + 25)).toBe(29)
  const idOffset = ptr + 72 + 8
  expect([...new Uint8Array(memory.buffer, idOffset, 12)]).toEqual([...Buffer.from(id, "hex")])
  expect(writer.id(1)).toBe(id)
  expect(writer.id(2)).toBeUndefined()

  vi.stubGlobal("TERRAIN_MASK_WALL", 1)
  writer.writeTerrain({
    get: (x: number, y: number) => (x === 0 && y === 0 ? 1 : 0),
  } as RoomTerrain)
  expect(view.getUint8(1816)).toBe(1)
  memory.grow(1)
  writer.beginTick(43, 0, 0, 0)
  view = new DataView(memory.buffer, ptr, INPUT_SIZE)
  expect(writer.id(1)).toBeUndefined()
  expect(view.getUint32(24, true)).toBe(0)
  expect(view.getUint32(20, true)).toBe(0)
  expect(view.getUint32(16, true)).toBe(0)
  writer.writeTerrain({ get: () => 0 } as unknown as RoomTerrain)
  expect(view.getUint8(1816)).toBe(0)
  expect(writer.writeSpawn(id, position, 50, 300, false)).toBe(true)
})

it("dispatches every command without temporary command records and refreshes output views", () => {
  const { memory, scratchPtr } = wasmFixture()
  const { CommandReader, Role, Part, Opcode } = loadGenerated()
  const reader = new CommandReader(memory, scratchPtr())
  memory.grow(1)
  const view = new DataView(memory.buffer, scratchPtr() + INPUT_SIZE, INPUT_SIZE)
  const opcodes = [
    Opcode.spawn,
    Opcode.move,
    Opcode.harvest,
    Opcode.transfer,
    Opcode.withdraw,
    Opcode.pickup,
    Opcode.upgrade,
  ]
  const commandSize = 44
  const sink = {
    spawn: vi.fn<CommandSink["spawn"]>(),
    move: vi.fn(),
    harvest: vi.fn(),
    transfer: vi.fn(),
    withdraw: vi.fn(),
    pickup: vi.fn(),
    upgrade: vi.fn(),
  }
  const offsets = { actorHandle: 20, targetHandle: 24, direction: 12, amount: 16, bodyLen: 8 }
  view.setUint32(0, opcodes.length, true)
  for (const [index, opcode] of opcodes.entries()) {
    const base = 4 + index * commandSize
    view.setUint32(base, opcode, true)
    view.setUint8(base + 4, Role.harvester)
    for (const [name, value] of Object.entries({
      actorHandle: 10,
      targetHandle: 20,
      direction: 3,
      amount: 123,
      bodyLen: 2,
    })) {
      view.setUint32(base + offsets[name as keyof typeof offsets], value, true)
    }
    view.setUint8(base + 28, Part.work)
    view.setUint8(base + 29, Part.move)
  }
  const written = 4 + opcodes.length * commandSize
  reader.dispatch(written, sink)
  expect(sink.spawn).toHaveBeenCalledWith(10, Role.harvester, expect.any(Uint8Array), 2)
  expect(Array.from(sink.spawn.mock.calls[0][2].subarray(0, 2))).toEqual([Part.work, Part.move])
  expect(sink.move).toHaveBeenCalledExactlyOnceWith(10, 3)
  for (const method of ["harvest", "pickup", "upgrade"] as const)
    expect(sink[method]).toHaveBeenCalledExactlyOnceWith(10, 20)
  for (const method of ["transfer", "withdraw"] as const)
    expect(sink[method]).toHaveBeenCalledExactlyOnceWith(10, 20, 123)
  reader.dispatch(written, sink)
  expect(sink.spawn.mock.calls[1][2]).toBe(sink.spawn.mock.calls[0][2])
  expect(() => reader.dispatch(written - 1, sink)).toThrow("Truncated command buffer")
  view.setUint32(4 + offsets.bodyLen, 999, true)
  expect(() => reader.dispatch(written, sink)).toThrow("Command array exceeds capacity")
})

it.each([
  [
    '"id", "pos", "energy", "energyCapacity", "spawning"',
    '"missing", "pos", "energy", "energyCapacity", "spawning"',
    "Unknown wire field",
  ],
  [
    '"id", "pos", "energy", "energyCapacity", "spawning"',
    '"id", "pos", "energy", "energyCapacity"',
    "every field exactly once",
  ],
  ['.codec = "hex_id"', '.codec = "unknown"', "Unknown codec"],
  [
    '.{ .method = "upgrade", .args = .{ "actorHandle", "targetHandle" } },',
    "",
    "Every opcode must have one callback",
  ],
])(
  "rejects invalid Zig metadata: %s",
  (original, replacement, message) => {
    const source = readFileSync(new URL("../../src/entry.zig", import.meta.url), "utf8")
    expect(source).toContain(original)
    const directory = mkdtempSync(join(tmpdir(), "spud-invalid-bindings-"))
    try {
      const fixturePath = join(directory, "entry.zig")
      writeFileSync(
        fixturePath,
        source
          .replace('@import("interop.zig")', '@import("interop")')
          .replace(original, replacement),
      )
      const result = spawnSync(
        "zig",
        [
          "build-obj",
          "-target",
          "wasm32-freestanding",
          "-fno-emit-bin",
          "--dep",
          "spud",
          "--dep",
          "interop",
          `-Mroot=${fixturePath}`,
          `-Mspud=${fileURLToPath(new URL("../../src/root.zig", import.meta.url))}`,
          `-Minterop=${fileURLToPath(new URL("../../src/interop.zig", import.meta.url))}`,
        ],
        { encoding: "utf8" },
      )
      expect(result.error).toBeUndefined()
      expect(result.status).not.toBe(0)
      expect(result.stderr).toContain(message)
    } finally {
      rmSync(directory, { recursive: true, force: true })
    }
  },
  30_000,
)
