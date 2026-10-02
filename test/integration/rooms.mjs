// Room fixtures for the integration tests. This module imports `xxscreeps:mods/*`, so it may only be
// loaded dynamically, after `xxscreeps/config/mods.js` has registered the loader hooks.
import { instanceOfPredicate } from "xxscreeps/functional/predicate.js"
import { RoomPosition } from "xxscreeps/game/position.js"
import {
  StructureController,
  updateRoomStatus,
} from "xxscreeps/mods/classic/controller/controller.js"
import { create as createSpawn } from "xxscreeps/mods/classic/spawn/spawn.js"
export const testUserId = "100"
export const testRoomName = "W9N9"

/**
 * Gives `userId` a claimed room with a spawn. Rooms imported from the shard payload already have a
 * controller, so it's claimed in place instead of creating a new one.
 */
export function claimedRoom({ userId = testUserId, withSpawn = true, level = 1 } = {}) {
  return (room) => {
    const controller = room["#objects"].find(instanceOfPredicate(StructureController))
    if (!controller) {
      throw new Error(`${room.name} has no controller`)
    }
    controller["#user"] = userId
    controller["#downgradeTime"] = 1_000_000
    updateRoomStatus(room, level, userId)
    if (withSpawn) {
      room["#insertObject"](createSpawn(new RoomPosition(25, 25, room.name), userId, "Spawn1"))
    }
  }
}
