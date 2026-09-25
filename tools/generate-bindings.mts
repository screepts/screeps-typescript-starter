import { readFile, writeFile } from "node:fs/promises"

async function generateFromWasm(wasmPath: string, outputPath: string): Promise<void> {
  const bytes = await readFile(wasmPath)
  const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), {})
  const exports = instance.exports as {
    memory: WebAssembly.Memory
    bindingsPtr: () => number
    bindingsLen: () => number
  }
  const source = new Uint8Array(exports.memory.buffer, exports.bindingsPtr(), exports.bindingsLen())
  await writeFile(outputPath, source)
}

await generateFromWasm(
  process.argv[2] ?? "zig-out/bin/spud.wasm",
  process.argv[3] ?? "src/bindings.generated.ts",
)
