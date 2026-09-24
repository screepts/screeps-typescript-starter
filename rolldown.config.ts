import { defineConfig, type PluginContext, type Plugin } from "rolldown"
import { spawn } from "node:child_process"
import screeps from "rollup-plugin-screeps-world"

export default defineConfig({
  input: "src/main.js",
  output: {
    format: "cjs",
    file: "dist/main.js",
    sourcemap: true,
    cleanDir: true,
  },
  external: ["main.js.map", "spud"],
  plugins: [
    zig(),
    screeps({
      server: process.env.DEST,
      dryRun: process.env.DEST === undefined,
    }),
  ],
})

/** `zig build` with watch */
function zig(): Plugin {
  return {
    name: "zig",
    async buildStart() {
      await run("zig", ["build", "--release", "--summary", "all"])

      const cwd = await this.fs.realpath(".")
      this.addWatchFile(joinPath(cwd, "build.zig"))
      this.addWatchFile(joinPath(cwd, "build.zig.zon"))
      await addWatchDir(this, cwd, ".zig")

      this.emitFile({
        type: "asset",
        fileName: "spud.wasm",
        source: await this.fs.readFile("zig-out/bin/spud.wasm"),
      })
    }
  }
}

async function addWatchDir(p: PluginContext, path: string, ext: string) {
  const entries = await p.fs.readdir(path, { withFileTypes: true })
  const dirs = []
  for (const entry of entries) {
    if (entry.isFile() && entry.name.endsWith(ext)) p.addWatchFile(joinPath(path, entry.name))
    if (entry.isDirectory()) dirs.push(addWatchDir(p, joinPath(path, entry.name), ext))
  }
  await Promise.all(dirs)
}
const joinPath = (...parts: string[]) => parts.join("/")

/** `execFile` with inherit stdout to preserve TTY colors */
function run(command: string, args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: "inherit" })
    child.on("error", reject)
    child.on("exit", (code) =>
      code === 0 ? resolve() : reject(new Error(`${command} exited with code ${code}`)),
    )
  })
}
