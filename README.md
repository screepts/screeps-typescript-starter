# Spud Screeps Bot

Spud is a competitive Screeps AI bot written in Zig with a thin Typescript binding.

## Requirements

You will need:

- [Node.JS](https://nodejs.org/en/download) (v24.x.x)
- [npm](https://docs.npmjs.com/getting-started/installing-node) (comes with Node.JS) or [bun](https://bun.sh/)
- [Zig](https://ziglang.org/download) (v0.16.x) or (`npm install -g @zigc/cli`)

## Architecture

- `src/root.zig` - pure, natively-testable game library (no wasm/byte-layout knowledge): `tick(TickInput) []Command`.
- `src/entry.zig` - the wasm boundary: `extern struct` wire records memory-mapped onto a shared scratch buffer export.
- `src/binding.ts` - encodes Screeps room state into the wire format, runs `loop()`, dispatches the returned commands as Screeps API calls.
- `src/main.ts` - initializes and `runTick()`.

## Development

- `npm run build` - compiles Zig (`zig build --release`) and bundles TS in one self-contained step.
- `npm run watch` - same, rebuilding on changes.
- `npm test` - `fmt:check` + `lint` + `test:unit` for both Zig and Typescript.
