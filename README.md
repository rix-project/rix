# zix

A Nix evaluator and package manager written in Zig.

**Last updated:** 2026-02-05

## Overview

~9,800 lines of Zig across 14 source files. Targets Zig 0.16 (uses `std.Io`, `std.process.Init`).

| Module | Lines | Description |
|---|---|---|
| `builtins.zig` | 1,779 | ~80 Nix builtins |
| `git.zig` | 1,750 | Native Git fetcher (pack protocol) |
| `parser.zig` | 1,260 | Recursive-descent Nix parser |
| `lexer.zig` | 939 | Nix lexer (strings, interpolation, indented strings) |
| `eval.zig` | 851 | Lazy evaluator with thunks, arena allocator |
| `flake.zig` | 798 | Flake loading, input resolution, output evaluation |
| `main.zig` | 481 | CLI: `eval`, `build`, `flake show/metadata/lock`, `repl` |
| `ast.zig` | 481 | AST node types |
| `fetcher.zig` | 315 | Fetcher abstraction (git, tarball, path) |
| `store.zig` | 309 | Store path computation, derivation hashing |
| `flakeref.zig` | 301 | Flake reference parsing (`github:`, `path:`, etc.) |
| `http.zig` | 290 | HTTP client (for fetchers) |
| `lockfile.zig` | 281 | `flake.lock` reading/writing |
| `io.zig` | 28 | IO utilities |

## What Works

### Lexer & Parser
- Full Nix expression syntax: let/in, with, if/then/else, functions, rec attrsets
- Nested string interpolation (`"${a + "${b}"}"`), indented strings (`''..''`)
- Dynamic attribute keys (`{ ${expr} = val; }`)
- Inherit, inherit-from (`inherit (expr) a b;`)
- Or-default expressions (`x.y or z`)
- Path literals, URI literals, multiline strings

### Evaluator
- **Lazy evaluation** — all attrset bindings are thunks, forced on demand
- **Arena allocator** — single arena owns all eval allocations; one `deinit()` frees everything
- Recursive attrset merging (`rec { }`)
- Dynamic attribute keys resolved at eval time
- Lambda application with pattern matching (formals with defaults, `@` patterns)
- Binary/unary operators (`+`, `-`, `*`, `/`, `++`, `//`, `==`, `!=`, `<`, `>`, `<=`, `>=`, `&&`, `||`, `!`, `->`)
- `with` scoping, `let ... in` bindings
- String interpolation evaluation
- `or`-default on attribute access

### Builtins (~80 registered)

**Fully implemented & thunk-forcing:**
- **Type checks:** `isNull`, `isFunction`, `isList`, `isAttrs`, `isString`, `isInt`, `isBool`, `isPath`, `isFloat`, `typeOf`
- **List:** `length`, `head`, `tail`, `elemAt`, `map`, `filter`, `foldl'`, `concatLists`, `genList`, `all`, `any`, `elem`, `sort`, `concatMap`, `catAttrs`, `groupBy`, `partition`, `genericClosure`, `zipAttrsWith`
- **Attrset:** `attrNames`, `attrValues`, `hasAttr`, `getAttr`, `removeAttrs`, `listToAttrs`, `intersectAttrs`, `mapAttrs`, `functionArgs`
- **String:** `stringLength`, `substring`, `concatStrings`, `concatStringsSep`, `replaceStrings`, `toString`, `split`
- **Math:** `add`, `sub`, `mul`, `div`, `lessThan`
- **JSON:** `toJSON`, `fromJSON`
- **Path/IO:** `import`, `readFile`, `readDir`, `readFileType`, `pathExists`, `toPath`, `baseNameOf`, `dirOf`
- **Control flow:** `seq`, `deepSeq`, `trace`, `throw`, `abort`, `tryEval` (actually catches errors), `addErrorContext`, `warn`
- **Derivation:** `derivation`/`derivationStrict`, `placeholder`
- **Version:** `compareVersions`, `splitVersion`, `parseDrvName`
- **Context (stubs):** `unsafeDiscardStringContext`, `hasContext`, `getContext`, `unsafeGetAttrPos`
- **Misc:** `getEnv`, `currentSystem`, `storeDir`, `nixVersion`, `langVersion`

**Stubbed / incomplete:**
- `match` — always returns `null` (no regex engine)
- `fetchurl`, `fetchTarball`, `fetchGit` (builtin versions) — return placeholder paths
- `deepSeq` — forces one level, not recursively
- `pathExists` — always returns `false`

### Flakes
- Parse `flake.nix` inputs (GitHub, path, git, indirect references)
- `follows` and nested follows (`inputs.x.inputs.y.follows`)
- Flake reference parsing (`github:owner/repo`, `path:.`, git URLs)
- Lock file reading (`flake.lock`)
- Input resolution with progress indicator
- Sub-flake evaluation (recursive flake input loading)
- Output evaluation — constructs the `outputs` function call with resolved inputs

### CLI
- `zix eval <file>` — evaluate a Nix expression and print the result
- `zix build [.#attr]` — evaluate flake outputs and select a build target
- `zix flake show` — display flake output tree
- `zix flake metadata` — display flake inputs and description
- `zix flake lock` — resolve inputs (write step not yet wired)
- `zix --lex` / `zix --parse` — debug modes for lexer/parser output

### Fetchers
- Native Git pack protocol client (smart HTTP)
- HTTP client for tarball fetching
- Path-based fetcher (local directories)
- Flake registry support

## Known Issues / Current Blockers

### `zix build` on flake-parts projects
The evaluator gets deep into the nixpkgs module system (lib.modules warnings are printed) but currently fails with `error.EmptyList` and then `error.AttributeNotFound`. Root causes:

1. **`builtins.match` is a stub** — returns `null` for all patterns. The nixpkgs `lib` uses regex matching extensively (e.g. `lib.strings`, version parsing). Without real regex support, many list-building paths produce empty lists or wrong results.

2. **`deepSeq` is shallow** — only forces one level instead of recursively traversing the value tree.

3. **No string context tracking** — Nix string contexts (store path references carried through string operations) are not implemented. `unsafeDiscardStringContext`, `hasContext`, `getContext` are stubs.

### Missing builtins
Some builtins that nixpkgs may need are not yet registered:
- `builtins.fetchTree`
- `builtins.getFlake`
- `builtins.storePath`
- `builtins.toFile`
- `builtins.filterSource` / `builtins.path`
- `builtins.hashString` / `builtins.hashFile`
- `builtins.fromTOML`
- `builtins.convertHash`
- `builtins.concatMapAttrs`
- `builtins.bitAnd` / `builtins.bitOr` / `builtins.bitXor`
- `builtins.ceil` / `builtins.floor`
- `builtins.tryEval` on deeply nested structures (currently only forces top-level)

### Other gaps
- **No actual building** — derivation evaluation produces store paths but no builder is invoked
- **No substituter** — no binary cache / download support
- **No sandboxing** — no build isolation
- **REPL** — declared but not implemented for the new IO API
- **Error messages** — errors propagate as Zig error codes without source location context
- **Float arithmetic** — math builtins only support `int`, not `float`
- **`//` (update) operator** — does not deep-merge (correct per Nix spec, but worth noting)

## Recent Changes (2026-02-05)

- **Arena allocator**: Replaced per-value tracking lists with a single heap-allocated `ArenaAllocator`. One `deinit()` frees all evaluator memory.
- **Thunk forcing in all builtins**: Fixed ~68 builtins that were not calling `evaluator.force()` on arguments before type-checking. This was causing `TypeError` whenever a lazy thunk was passed to any builtin.
- **`mapAttrs` rewrite**: Was completely broken (returned input unchanged without applying the function). Now properly applies `f name value` for each attribute.
- **`tryEval` fix**: Now actually forces the argument and catches errors, returning `{ success = false; value = false; }` on failure.
- **Lexer string lifetime fix**: `Lexer.deinit()` no longer frees allocated strings, since the arena's `free()` can reclaim recent allocations and the debug allocator then poisons the memory with `0xAA`, causing garbled strings in the AST.

## Architecture Notes

```
main.zig ─── CLI argument parsing, mode dispatch
  ├── lexer.zig ─── Tokenization (string interpolation, indented strings)
  ├── parser.zig ─── Recursive-descent parser → ast.zig AST nodes
  ├── eval.zig ─── Lazy evaluator (thunks, environments, arena allocator)
  │   └── builtins.zig ─── ~80 builtin functions
  ├── flake.zig ─── Flake loading, resolution, evaluation
  │   ├── flakeref.zig ─── Flake reference types and parsing
  │   ├── lockfile.zig ─── flake.lock read/write
  │   └── fetcher.zig ─── Fetch abstraction
  │       ├── git.zig ─── Native Git smart-HTTP pack protocol
  │       └── http.zig ─── HTTP client
  └── store.zig ─── Store path computation, system detection
```

**Key design decisions:**
- All evaluation memory is owned by a single `ArenaAllocator` — no individual frees needed during evaluation
- The arena is heap-allocated (not inline in the `Evaluator` struct) so its address stays stable across struct moves
- Lazy evaluation: all attrset bindings become thunks; `force()` is iterative (loop, not recursion) to avoid stack overflow
- Builtins receive `eval_ctx: ?*Evaluator` to call `force()`, `apply()`, and `eval()` during execution
- Builtin currying: multi-arg builtins use `arity` + `partial_args` to auto-curry (e.g. `map f` returns a partial, `map f list` calls the function)
