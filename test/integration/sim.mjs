// A minimal in-process xxscreeps server, ported from the unpublished
// `packages/xxscreeps/test/simulate.ts` harness.
import "xxscreeps/config/mods.js"

import * as fs from "node:fs/promises"
import { createRequire } from "node:module"
import { config } from "xxscreeps/config/index.js"
import { kFdStdError, kFdStdOut } from "xxscreeps/driver/runtime/print.js"
import { loadTerrain } from "xxscreeps/driver/pathfinder/pathfinder.js"
import { consumeSet, consumeSortedSet } from "xxscreeps/engine/db/async.js"
import { Database, Shard } from "xxscreeps/engine/db/index.js"
import * as Code from "xxscreeps/engine/db/user/code.js"
import * as User from "xxscreeps/engine/db/user/index.js"
import {
  initializeIntentConstraints,
  makeInitializeRoomForProcessor,
} from "xxscreeps/engine/processor/index.js"
import {
  acquireIntentsForRoom,
  activeRoomsKey,
  begetRoomProcessQueue,
  finalizeExtraRoomsSetKey,
  processRoomsSetKey,
  updateUserRoomRelationships,
  userToIntentRoomsSetKey,
  userToVisibleRoomsSetKey,
} from "xxscreeps/engine/processor/model.js"
import { RoomProcessor } from "xxscreeps/engine/processor/room.js"
import { runShardTickProcessors } from "xxscreeps/engine/processor/shard.js"
import {
  PlayerInstance,
  acquireRunnerContext,
  makeTickPayloadForTesting,
} from "xxscreeps/engine/runner/instance.js"
import { getConsoleChannel } from "xxscreeps/engine/runner/model.js"
import * as Id from "xxscreeps/engine/schema/id.js"
import { Fn } from "xxscreeps/functional/fn.js"
import {
  Game,
  GameState,
  initializeGameEnvironment,
  runForPlayer,
  runForUser,
  runOneShot,
  runWithState,
} from "xxscreeps/game/index.js"
import * as MapSchema from "xxscreeps/game/map.js"
import { flushUsers } from "xxscreeps/game/room/room.js"
import * as Memory from "xxscreeps/mods/meta/memory/memory.js"
import { importPayload, seedShard } from "xxscreeps/scripts/payload.js"
import { getOrSet } from "xxscreeps/utility/utility.js"

// Both main and worker logic run in this process, so load every slot either service would use
import "xxscreeps:mods/driver"
import "xxscreeps:mods/game"
import "xxscreeps:mods/main"
import "xxscreeps:mods/processor"

const require = createRequire(import.meta.url)
const payload = JSON.parse(
  await fs.readFile(require.resolve("xxscreeps/scripts/data/shard.json"), "utf8"),
)
const payloadWorld = importPayload(payload)
const world = new MapSchema.World("test", payloadWorld.terrain)
// Seeds the path finder's global terrain as a side effect
loadTerrain(world)

const initializeRoom = makeInitializeRoomForProcessor()
initializeGameEnvironment()
initializeIntentConstraints()

const defaultUsers = { ...User.npcUsers, 100: "Player 1" }

export { world }

/**
 * Creates a factory for a fresh in-memory shard. `rooms` maps room names to callbacks which run
 * with full game privileges and may add or modify objects in the room.
 */
export function simulate(rooms = {}, initialize) {
  return async (body) => {
    Memory.initialize(null)
    const stack = new AsyncDisposableStack()
    const syncStack = new DisposableStack()

    const db = stack.use(await Database.connect({ data: "local://data", pubsub: "local://pubsub" }))
    const shard = stack.use(
      await Shard.connectWith(db, {
        name: "shard0",
        data: "local://keyval",
        pubsub: "local://pubsub",
        scratch: "local://scratch",
      }),
    )
    await Promise.all([db.data.flushdb(), shard.data.flushdb(), shard.scratch.flushdb()])
    await Promise.all([
      seedShard(shard, payloadWorld),
      ...Fn.map(Object.entries(defaultUsers), ([userId, username]) =>
        User.create(db, userId, username),
      ),
    ])

    await Promise.all(
      Fn.map(Object.entries(rooms), async ([roomName, callback]) => {
        const room = await shard.loadRoom(roomName, shard.time)
        runOneShot(world, room, shard.time, "", () => callback(room))
        room["#flushObjects"](null)
        const previousUsers = flushUsers(room)
        await Promise.all([
          shard.saveRoom(room.name, shard.time, room),
          // Mirror the processor worker's `initialize` step so mods' indices (eg the set of rooms a
          // player controls) see the rooms the test starts with
          initializeRoom(shard, room, previousUsers),
          // The main service seeds NPC-driven rooms into the active set when it boots
          room["#npcData"].users.size > 0 && shard.scratch.zAdd(activeRoomsKey, [[0, roomName]]),
        ])
      }),
    )
    await initialize?.(shard)

    const intentsByRoom = new Map()
    const playersThisTick = new Set()
    const sandboxPlayers = []
    let roomInstances = new Map()

    const that = {
      db,
      shard,
      world,

      /** Runs `task` in the user's game context and queues any intents it issues for `tick`. */
      async player(userId, task) {
        if (playersThisTick.has(userId)) {
          throw new Error(`player '${userId}' already invoked this tick`)
        }
        playersThisTick.add(userId)
        const [intentRooms, visibleRooms, tickPayload] = await Promise.all([
          shard.scratch.sMembers(userToIntentRoomsSetKey(userId)),
          shard.scratch.sMembers(userToVisibleRoomsSetKey(userId)),
          makeTickPayloadForTesting(shard, world, userId),
        ])
        const rooms = await Promise.all(
          Fn.map(visibleRooms, (roomName) => shard.loadRoom(roomName)),
        )
        const state = new GameState(world, shard.time, rooms)
        const [intents] = runForPlayer(userId, state, tickPayload, task)
        for (const roomName of intentRooms) {
          const roomIntents = intents.getIntentsForRoom(roomName)
          if (roomIntents) {
            getOrSet(intentsByRoom, roomName, () => []).push({ userId, intents: roomIntents })
          }
        }
      },

      /** Reads a room without giving the caller any way to modify or dispatch intents. */
      async peekRoom(roomName, task) {
        const room = await shard.loadRoom(roomName)
        return runOneShot(world, room, shard.time, "", () => task(room, Game))
      },

      /**
       * Like `player`, but only one room is loaded and the room is saved afterwards. Intents are
       * discarded.
       */
      async poke(roomName, userId, task) {
        const room = await shard.loadRoom(roomName)
        const state = new GameState(world, shard.time, [room])
        const [, result] = runWithState(state, () =>
          runForUser(userId ?? "", state, (Game) => task(Game, room)),
        )
        room["#flushObjects"](state)
        const previousUsers = flushUsers(room)
        await Promise.all([
          shard.saveRoom(room.name, shard.time, room),
          updateUserRoomRelationships(shard, room, previousUsers),
        ])
        roomInstances.delete(roomName)
        return result
      },

      /**
       * Uploads a code bundle and runs it in a sandbox every tick. `bundle` is either a path to a
       * built bundle or the bundle source itself. The returned instance collects what the script
       * wrote to the console in `logs` and everything it wrote to stderr in `errors`.
       */
      async sandbox(userId, bundle, { logSandbox = false } = {}) {
        config.runner.sandbox = "unsafe"
        if ((await db.data.hGet(User.infoKey(userId), "username")) === null) {
          await User.create(db, userId, Id.generateId(12), [])
        }
        const code =
          typeof bundle === "string" && (await exists(bundle))
            ? await fs.readFile(bundle, "utf8")
            : bundle
        await Code.saveContent(db, userId, "main", new Map([["main", code]]))
        const errors = []
        const logs = []
        const runner = stack.use(await acquireRunnerContext(shard))
        const instance = await PlayerInstance.create(runner, world, userId)
        stack.use({ [Symbol.asyncDispose]: async () => instance.disconnect() })
        syncStack.defer(
          await getConsoleChannel(shard, userId).listen((payload) => {
            for (const { data, fd } of JSON.parse(payload)) {
              if (fd === kFdStdOut) {
                logs.push(String(data))
              }
              if (fd === kFdStdError && data !== "Script was disposed") {
                errors.push(String(data))
              }
              if (logSandbox) {
                console.log(`[${userId}] ${data}`)
              }
            }
          }),
        )
        sandboxPlayers.push(instance)
        return Object.assign(instance, { errors, logs })
      },

      /**
       * Runs the game processor, dispatching intents.
       * @param count Number of ticks
       * @param players Record of user ids to game callbacks to run each tick
       */
      async tick(players, count = 1) {
        playersThisTick.clear()
        for (let index = 0; index < count; ++index) {
          const time = shard.time
          if (players) {
            for (const [userId, task] of Object.entries(players)) {
              await that.player(userId, task)
            }
          }
          playersThisTick.clear()

          for (const instance of sandboxPlayers) {
            const { userId } = instance
            const [intentRooms, visibleRooms] = await Promise.all([
              shard.scratch.sMembers(userToIntentRoomsSetKey(userId)),
              shard.scratch.sMembers(userToVisibleRoomsSetKey(userId)),
            ])
            await instance.run(time, visibleRooms, intentRooms)
          }

          await begetRoomProcessQueue(shard, time)
          const nextRoomInstances = new Map()
          const contexts = new Map()
          for await (const roomName of consumeSortedSet(
            shard.scratch,
            processRoomsSetKey(time),
            0,
            Infinity,
          )) {
            const room = roomInstances.get(roomName) ?? (await shard.loadRoom(roomName))
            nextRoomInstances.set(roomName, room)
            const context = new RoomProcessor(shard, world, room, time)
            contexts.set(roomName, context)
            const scratchIntents = await acquireIntentsForRoom(shard, roomName)
            const inMemoryIntents = intentsByRoom.get(roomName) ?? []
            for (const { userId, intents } of [...inMemoryIntents, ...scratchIntents]) {
              context.saveIntents(userId, intents)
            }
            await context.process()
          }
          roomInstances = nextRoomInstances
          intentsByRoom.clear()

          await Promise.all(Fn.map(contexts.values(), (context) => context.finalize(false)))
          for await (const roomName of consumeSet(shard.scratch, finalizeExtraRoomsSetKey(time))) {
            const room = roomInstances.get(roomName) ?? (await shard.loadRoom(roomName))
            const context = new RoomProcessor(shard, world, room, time)
            await context.process(true)
            await context.finalize(true)
            nextRoomInstances.set(roomName, room)
          }

          await runShardTickProcessors(shard, time)

          const nextTime = time + 1
          await shard.data.set("time", nextTime)
          await shard.channel.publish({ type: "tick", time: nextTime })
          shard.time = nextTime
        }
      },
    }

    try {
      // `await` so the body runs while the shard is still alive
      return await body(that)
    } finally {
      syncStack.dispose()
      await stack.disposeAsync()
    }
  }
}

async function exists(file) {
  try {
    await fs.access(file)
    return true
  } catch {
    return false
  }
}
