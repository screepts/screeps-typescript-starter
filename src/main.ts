import { ErrorMapper } from "utils/ErrorMapper"
import { runTick } from "binding"

export const loop = ErrorMapper.wrapLoop(() => {
  for (const name in Memory.creeps) {
    if (!(name in Game.creeps)) delete Memory.creeps[name]
  }

  runTick()
})

declare const global: Record<string, unknown>
global.log = (...args: any[]) => console.logUnsafe("LOG:", ...args)
