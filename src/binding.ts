import {
  AMOUNT_ALL,
  CommandReader,
  Part,
  Role,
  WorldWriter,
  type CommandSink,
} from "./bindings.generated"

interface WasmExports {
  memory: WebAssembly.Memory
  scratchPtr: () => number
  loop: () => number
}

declare const require: (path: "spud") => ArrayBuffer

function partForCode(code: number): BodyPartConstant {
  switch (code) {
    case Part.work:
      return WORK
    case Part.carry:
      return CARRY
    case Part.move:
      return MOVE
    default:
      throw new Error(`Unknown body part: ${code}`)
  }
}

function roleOf(memory: CreepMemory | undefined): Role {
  const role = memory && Role[memory.role as keyof typeof Role]
  return typeof role === "number" ? role : Role.none
}

class Bridge implements CommandSink {
  private readonly writer: WorldWriter
  private readonly reader: CommandReader
  private terrainRoom: string | undefined
  private roomName = ""

  constructor(private readonly exports: WasmExports) {
    const ptr = exports.scratchPtr()
    this.writer = new WorldWriter(exports.memory, ptr)
    this.reader = new CommandReader(exports.memory, ptr)
  }

  run(room: Room): void {
    const match = /^([WE])(\d+)([NS])(\d+)$/.exec(room.name)
    if (match == null) throw new Error(`Invalid room name: ${room.name}`)
    const wx = match[1] === "W" ? -parseInt(match[2], 10) - 1 : parseInt(match[2], 10)
    const wy = match[3] === "N" ? -parseInt(match[4], 10) - 1 : parseInt(match[4], 10)
    const writer = this.writer
    writer.beginTick(Game.time, Math.max(0, Game.cpu.bucket), wx, wy)
    this.roomName = room.name
    if (this.terrainRoom !== room.name) {
      writer.writeTerrain(room.getTerrain())
      this.terrainRoom = room.name
    }

    const controller = room.controller
    if (controller) {
      writer.writeController(
        controller.id,
        controller.pos,
        controller.level,
        controller.progress,
        controller.progressTotal,
        controller.my,
      )
    }
    for (const spawn of room.find(FIND_MY_SPAWNS)) {
      if (
        !writer.writeSpawn(
          spawn.id,
          spawn.pos,
          spawn.store.getUsedCapacity(RESOURCE_ENERGY),
          spawn.store.getCapacity(RESOURCE_ENERGY) ?? 0,
          Boolean(spawn.spawning),
        )
      )
        break
    }
    for (const source of room.find(FIND_SOURCES)) {
      if (!writer.writeSource(source.id, source.pos, source.energy, source.energyCapacity)) break
    }
    for (const creep of room.find(FIND_MY_CREEPS)) {
      if (
        !writer.writeCreep(
          creep.id,
          creep.pos,
          creep.store.getUsedCapacity(RESOURCE_ENERGY),
          creep.store.getCapacity(RESOURCE_ENERGY) ?? 0,
          roleOf(creep.memory),
          creep.getActiveBodyparts(WORK),
          creep.getActiveBodyparts(CARRY),
          creep.getActiveBodyparts(MOVE),
          creep.spawning,
        )
      )
        break
    }
    for (const resource of room.find(FIND_DROPPED_RESOURCES)) {
      if (resource.resourceType !== RESOURCE_ENERGY) continue
      if (!writer.writeDropped(resource.id, resource.pos, Math.min(resource.amount, 0xffffffff)))
        break
    }
    this.reader.dispatch(this.exports.loop(), this)
  }

  private object<T extends _HasId>(handle: number): T | null {
    const id = this.writer.id(handle)
    return id ? Game.getObjectById<T>(id) : null
  }

  spawn(actorHandle: number, role: Role, body: Uint8Array, bodyLength: number): void {
    const spawn = this.object<StructureSpawn>(actorHandle)
    if (!spawn) return
    const parts: BodyPartConstant[] = []
    for (let index = 0; index < bodyLength; index++) parts.push(partForCode(body[index]))
    const name = Role[role]
    spawn.spawnCreep(parts, `${name}_${Game.time}`, {
      memory: { role: name, room: this.roomName, working: false },
    })
  }

  move(actorHandle: number, direction: number): void {
    this.object<Creep>(actorHandle)?.move(direction as DirectionConstant)
  }

  harvest(actorHandle: number, targetHandle: number): void {
    const creep = this.object<Creep>(actorHandle)
    const target = this.object<Source>(targetHandle)
    if (creep && target) creep.harvest(target)
  }

  transfer(actorHandle: number, targetHandle: number, amount: number): void {
    const creep = this.object<Creep>(actorHandle)
    const target = this.object<AnyCreep | Structure>(targetHandle)
    if (creep && target)
      creep.transfer(target, RESOURCE_ENERGY, amount === AMOUNT_ALL ? undefined : amount)
  }

  withdraw(actorHandle: number, targetHandle: number, amount: number): void {
    const creep = this.object<Creep>(actorHandle)
    const target = this.object<Structure>(targetHandle)
    if (creep && target)
      creep.withdraw(target, RESOURCE_ENERGY, amount === AMOUNT_ALL ? undefined : amount)
  }

  pickup(actorHandle: number, targetHandle: number): void {
    const creep = this.object<Creep>(actorHandle)
    const target = this.object<Resource>(targetHandle)
    if (creep && target) creep.pickup(target)
  }

  upgrade(actorHandle: number, targetHandle: number): void {
    const creep = this.object<Creep>(actorHandle)
    const target = this.object<StructureController>(targetHandle)
    if (creep && target) creep.upgradeController(target)
  }
}

let bridge: Bridge | undefined

export function runTick(): void {
  for (const name in Game.rooms) {
    const room = Game.rooms[name]
    if (!room.controller?.my) continue
    if (!bridge) {
      const module = new WebAssembly.Module(require("spud"))
      const instance = new WebAssembly.Instance(module, {})
      bridge = new Bridge(instance.exports as unknown as WasmExports)
    }
    bridge.run(room)
    return
  }
}
