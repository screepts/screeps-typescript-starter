# Spud Screeps Bot

Spud is a competitive Screeps AI bot written in Zig with a thin Typescript binding.

## Requirements

You will need:

- [Node.JS](https://nodejs.org/en/download) (v24.x.x)
- [npm](https://docs.npmjs.com/getting-started/installing-node) (comes with Node.JS) or [bun](https://bun.sh/)
- [Zig](https://ziglang.org/download) (v0.16.x) or (`npm install -g @zigc/cli`)

## Architecture

- `src/root.zig` - pure, natively-testable game library (no wasm/byte-layout knowledge): `tick(TickInput) []Command`.
- `src/entry.zig` - wire records and their static `binding` metadata, memory-mapped onto a shared scratch buffer.
- `src/interop.zig` - generates TypeScript source at comptime directly from wire types, offsets, capacities, enums, and binding metadata.
- `tools/generate-bindings.mts` - extracts the generated source from the compiled wasm32 module and writes it to disk.
- `src/bindings.generated.ts` - generated `WorldWriter`, `CommandReader`, enums, and typed `CommandSink`. Do not edit by hand.
- `src/binding.ts` - passes Screeps values to the writer, runs `loop()`, and implements command callbacks as Screeps API calls.
- `src/main.ts` - initializes and `runTick()`.

## Binding Generation

`zig build` and `zig build test` generate the TypeScript binding at Zig comptime
using the actual wasm32 target layout. The source is exported as bytes from the
same Wasm artifact used by the bot. Run `zig build bindings` to regenerate it explicitly.
Node and the installed npm development dependencies are required only to extract,
format, and write that source; Node performs no reflection or code generation.
The generated file is checked in for editor support and rewritten only when its
content changes. There is no intermediate JSON schema or ABI version check.

`Id(target)` owns hex encoding and transient string interning metadata;
`Position` maps its fields directly to an existing `RoomPosition`. Each record's
`binding` declares its writer method and argument order. `World.binding` associates
record collections with count fields, and `CommandRecord.binding` defines callback
arguments for each opcode. Unknown fields, incomplete mappings, unsupported types,
and missing command callbacks fail Zig compilation.

Writers take flat arguments without temporary record objects or caller-managed
offsets. `beginTick` clears counts and handles; record methods update counts and
return `false` at capacity. Input and output views refresh when Wasm memory grows.
Command callbacks receive scalar arguments directly. Spawn body bytes use one
reusable buffer plus a length; consume it synchronously rather than retaining it.

## Development

- `npm run build` - compiles Zig (`zig build --release`) + interop and bundles TS in one self-contained step.
- `npm run watch` - same, rebuilding on changes.
- `npm test` - `fmt:check` + `lint` + `test:unit` for both Zig and Typescript.
