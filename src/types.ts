declare global {
  // Memory extension samples
  interface Memory {
    uuid: number
    log: any
  }

  interface CreepMemory {
    role: string
    room: string
    working: boolean
  }

  // Screeps IVM provides a real WebAssembly global at runtime
  // But the "dom" lib pulls in far more (fetch, window, ...) than what is available
  // So declare just the pieces binding.ts actually uses.
  namespace WebAssembly {
    class Module {
      constructor(bytes: ArrayBuffer | Uint8Array)
    }

    class Instance {
      constructor(module: Module, imports?: Record<string, unknown>)
      readonly exports: Record<string, unknown>
    }

    class Memory {
      constructor(descriptor: { initial: number; maximum?: number })
      readonly buffer: ArrayBuffer
    }
  }
}

export {}
