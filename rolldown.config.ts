import { defineConfig } from "rolldown"
import screeps from "rollup-plugin-screeps-world"

export default defineConfig({
  input: "src/main.js",
  output: {
    format: "cjs",
    file: "dist/main.js",
    sourcemap: true,
    cleanDir: true,
  },
  external: ["main.js.map"],
  plugins: [
    screeps({
      server: process.env.DEST,
      dryRun: process.env.DEST === undefined,
    }),
  ],
})

declare var process: {
  env: {
    DEST?: string
  }
}
