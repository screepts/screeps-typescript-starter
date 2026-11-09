// `xxscreeps/config/mods.js` registers the Node loader hooks which resolve the `xxscreeps:mods/*` scheme.
// Not compatible with Vitest as it tries to rewrite module resolution as well.
import "xxscreeps/config/mods.js"

import * as assert from "node:assert/strict"
import * as path from "node:path"
import { test } from "node:test"
import { fileURLToPath } from "node:url"

const { simulate } = await import("./sim.ts")
const { claimedRoom, testRoomName: roomName, testUserId: userId } = await import("./rooms.ts")

const spawn = { x: 36, y: 14 }
const simOne = (
  run: (
    sandbox: (
      bundle: any,
      opts?: { logSandbox?: boolean },
    ) => Promise<{ errors: string[]; logs: string[] }>,
    tick: (task: (game: Game) => void, count?: number) => Promise<void>,
  ) => Promise<void>,
) =>
  simulate({ [roomName]: claimedRoom({ spawn }) })(async (sim) =>
    run(
      (bundle, opts) => sim.sandbox(userId, bundle, opts),
      (task, count) => sim.tick({ [userId]: task }, count),
    ),
  )

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..")
const distMain = path.join(root, "dist/main.js")

await test("is upgrading controller", async () => {
  await simOne(async (sandbox, tick) => {
    await test("loads code", async () => {
      const bot = await sandbox(distMain, { logSandbox: process.env.LOG_SANDBOX === "1" })
      assert.deepEqual(bot.errors, [])
    })

    await test("spawns its first creep", async () => {
      let creeps = []
      await tick((Game) => {
        creeps = Object.keys(Game.creeps)
      }, 5)
      assert.ok(creeps.length > 0)
    })

    await test("upgrades controller", async () => {
      let progress = 0
      for (let i = 0; i < 2000 && !progress; i++) {
        await tick((Game) => {
          progress = Game.rooms[roomName].controller?.progress ?? 0
        })
      }
      assert.notEqual(progress, 0)
    })
  })
})
