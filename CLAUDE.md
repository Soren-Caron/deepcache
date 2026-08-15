# Build rules for DEEPCACHE

Read this before writing code. It exists so work done in separate sessions composes instead of colliding.

## The one rule everything else follows from

**All gameplay logic lives in engine-free pure Luau under `src/shared/core/`. Roblox-facing code is a thin adapter.**

A module in `core/` may not reference `game`, `workspace`, `Instance`, `task`, `RunService`, `Players`, `HttpService`, `os.time`, or any other Roblox global. It takes plain tables and numbers in, returns plain tables and numbers out. Time is always an injected parameter, never read from a clock.

Why: `core/` runs under Lune in a terminal, which means it is unit-testable without Studio, without a human, and without a play session. That is what makes autonomous progress possible. Adapters are where Studio verification is needed, so they must stay small enough that a smoke test covers them.

If you find yourself wanting a Roblox API inside `core/`, the answer is to pass the value in as an argument.

## Definition of done for any task

1. `lune run tests` passes (all pure-core tests green).
2. `npm --prefix backend test` passes, if backend code changed.
3. New logic in `core/` has tests covering the boundary conditions named in the task, not just a happy path.
4. `rojo build` succeeds.
5. If it touches an adapter, a Studio smoke check ran via MCP `execute_luau` and its output is quoted in the commit message.
6. The relevant doc under `docs/` is updated in the same commit if behavior diverged from the spec. **The spec is not sacred — but silent divergence is forbidden.**

Do not report a task complete with a failing or skipped test. If a test can't pass, say which one and why.

## Require convention (verified in Studio, M0)

Use **relative string requires** everywhere in `src/`: `require("./Sibling")` and `require("../util/Rng")`. Both forms were tested in Studio and under Lune and work identically in both, including chained traversal across subdirectories.

- **Do not use `@self/`** in `src/`. It works under Lune and **fails in Roblox** (`could not resolve child component`). It appears only in `tests/init.luau`, which is Lune-only.
- **Do not use `script.Parent`** in `src/shared/core/` — it's a Roblox global and breaks Lune.
- Test files require core modules by path from `tests/`: `require("../src/shared/core/net/Quantize")`.

Inside an `init.luau`, Lune resolves `./` against the *parent* directory, not the file's own directory. That's why `tests/init.luau` uses `@self/`. Avoid `init.luau` in `src/` entirely and the ambiguity never arises.

**Relative requires cannot cross services.** `src/shared` maps to `ReplicatedStorage.Shared`, `src/server` to `ServerScriptService.Server`, `src/client` to `StarterPlayerScripts.Client`. Relative paths traverse the DataModel, so they work *within* one mapped subtree and fail across two: `require("../shared/config/Netcode")` from a server module resolves to `ServerScriptService.shared`, which does not exist. It compiles, syncs, and then fails at boot.

From `src/server` or `src/client`, reach shared code by Instance:

```lua
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local NetcodeConfig = require(Shared.config.Netcode)
```

Within a subtree, keep using relative requires (`require("./EntityService")`, `require("../services/TickService")`). `lune run tools/check-syntax` lints the cross-service case.

## Studio verification runs in a separate module registry

The command bar — and therefore the MCP bridge — has its own `require` cache. `require(ServerScriptService.Server.services.TickService)` from there returns a **fresh, idle copy**, not the instance the boot script started, and `_G` does not cross either. It will cheerfully report zero ticks while the server is visibly running.

Go through `ServerStorage.DeepcacheDiagnostics` (a `BindableFunction`) instead. `Bootstrap.server` registers handlers from the running context; the bridge invokes them:

```lua
local bridge = game:GetService("ServerStorage"):WaitForChild("DeepcacheDiagnostics")
return bridge:Invoke("bench", { entities = 40, ticks = 200 })
```

Register a new handler in `Bootstrap.server` rather than reaching into services from the command bar.

## Conventions

- **Luau, strict mode.** `--!strict` at the top of every file. Fix type errors rather than casting to `any`.
- **Never annotate a type on a table-field assignment.** `Foo.BAR: {string} = {...}` is a syntax error in Luau. Declare `local BAR: {string} = {...}` then `Foo.BAR = BAR`.
- **Naming:** `PascalCase` for modules and types, `camelCase` for locals and fields, `SCREAMING_SNAKE` for constants. Files match the module name.
- **No magic numbers in logic files.** Tunables go in `src/shared/config/*.luau`, which is pure data — no functions, no requires.
- **Remotes are declared once** in `src/shared/net/Remotes.luau` and accessed only through it. Never `WaitForChild` a remote inline.
- **Errors:** server-side validation failures return `(false, reason: string)`, they do not throw. Throwing is for programmer error only.
- **Never trust the client** for damage, position-as-truth, currency, loot contents, or time. Client timestamps are *hints* that get clamped, never authorities.

## Things that will silently break if you forget them

- **Never write a `.luau` file from Windows PowerShell 5.1 with `Set-Content -Encoding UTF8` or `Out-File -Encoding utf8`.** Both emit a UTF-8 BOM, and 5.1 has no `utf8NoBOM`. Luau then fails with `Expected identifier ... got Unicode character U+feff` pointing at line 1, which tells you nothing about what wrote it. Use the Write tool, or `[System.IO.File]::WriteAllText(path, text, [System.Text.UTF8Encoding]::new($false))`. `lune run tools/check-encoding` guards this and runs in CI.
- **Luau string interpolation rejects `{{`.** Write `\{` to emit a literal brace inside a backtick string.

- `UnreliableRemoteEvent` **drops payloads over ~1000 bytes.** The snapshot serializer has a hard 900-byte budget with a runtime assert. Do not raise it.
- `HttpService` is capped at **500 requests/minute per game server**. Everything outbound batches. Adding a new per-event HTTP call is a design error, not an optimization problem.
- Any text produced by the LLM and shown to a player **must** pass through `TextService:FilterStringAsync` first. No exceptions, including "just for testing." Failing the filter means falling back to a canned line, never showing the raw text.
- `EditableImage` is capped at **8 live instances on the client.** The look pipeline budgets these explicitly; releasing them is mandatory.
- DataStore writes are rate-limited per key. Currency changes go through the ledger's write-behind queue, never a direct `SetAsync` per transaction.

## Model choices (already decided, don't re-litigate)

- Director ticks: `claude-haiku-4-5` — latency-critical, structured JSON, cheap.
- Pre-run briefing and post-run debrief: `claude-opus-5` — not latency-critical, quality matters.
- Rationale and cost math: [docs/05-OVERSEER-DIRECTOR.md](docs/05-OVERSEER-DIRECTOR.md).

## When the spec is wrong

It will be, somewhere. Write down what you found, change the doc, then change the code. A task that ends with "the spec said X but X doesn't work because Y, so I did Z and updated docs/NN" is a good outcome. A task that quietly does Z is not.

## What not to do

- Don't add a system that isn't in `docs/10-ROADMAP.md` for the current milestone. Scope creep is the failure mode this project is most exposed to.
- Don't build the fun parts before the load-bearing parts. Netcode and telemetry gate everything downstream.
- Don't use Studio-typed code as the source of truth. Source of truth is on disk, synced in by Rojo. Studio is for verification and play.
