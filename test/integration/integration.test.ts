// `xxscreeps/config/mods.js` registers the Node loader hooks which resolve the `xxscreeps:mods/*` scheme.
// Not compatible with Vitest as it tries to rewrite module resolution as well.
import "xxscreeps/config/mods.js"

import * as assert from "node:assert/strict"
import * as path from "node:path"
import { test } from "node:test"
import { fileURLToPath } from "node:url"

const { simulate } = await import("./sim.mjs")
const { claimedRoom, testRoomName: kRoomName, testUserId: kUserId } = await import("./rooms.mjs")

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..")
const distMain = path.join(root, "dist/main.js")

test("is upgrading controller", async () => {
  await simulate({ [kRoomName]: claimedRoom() })(async ({ sandbox, tick }) => {
    await test("loads code", async () => {
      const bot = await sandbox(kUserId, distMain, { logSandbox: process.env.LOG_SANDBOX === "1" })
      assert.deepEqual(bot.errors, [])
    })

    await test("spawns its first creep", async () => {
      let creeps = []
      await tick({
        [kUserId]: (Game) => {
          creeps = Object.keys(Game.creeps)
        },
      }, 5)
      assert.ok(creeps.length > 0)
    })

    await test("upgrades controller", async () => {
      let progress = 0
      for (let i = 0; i < 2000 && !progress; i++) {
        await tick({
          [kUserId]: (Game) => {
            progress = Game.rooms[kRoomName].controller?.progress ?? 0
          },
        })
      }
      assert.notEqual(progress, 0)
    })
  })
})
