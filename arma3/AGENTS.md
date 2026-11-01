# AGENTS.md

Thin arma-rs + SQF wrapper around [`minerva-server`](../server): pushes Arma state into its
`StateCache` and executes commands it dispatches back. File paths are relative to this
directory; `cargo` commands run from the repo root, `hemtt` from here.

## Layout

- `src/lib.rs` — the `#[arma] fn init()` entry point and the command handlers arma-rs
  routes SQF `callExtension` calls to (`start`, `stop`, `reset`, `sim:info`, `sim:state`,
  `group:upsert`/`remove`, `unit:remove`, `command:ack`). Global state is a
  `Mutex<Option<ServerHandle>>` — commands other than `start` fail with "not started"
  until it's set. There is no `unit:upsert`: a unit's state only ever arrives embedded in
  its group's `group:upsert` (see below) -- `unit:remove` stays standalone, for the
  immediate removal `XEH_postInit.sqf`'s `EntityKilled`/`EntityDeleted` handlers send.
- `src/convert.rs` — Arma value <-> protocol/domain type conversions (side strings, unit
  category, damage->health, wind vector -> speed/direction, Arma `date` -> unix time,
  `unit_from_parts` building the `Unit` embedded in a `group:upsert`).
- `src/sink.rs` — `ArmaCommandSink`: turns a dispatched `minerva_server::Command` into an
  `ExtensionCallback` (`context.callback_data("minerva", "command", [id, type, groupId, ...])`),
  picked up by `fnc_onCallback`/`fnc_executeCommand` on the SQF side. Its `SUPPORTED` list
  (move, search and destroy, patrol) is what `GetSimulationInfo` advertises and all the server
  will dispatch to it: a new command type needs a `case` in `fnc_executeCommand.sqf` and an
  entry there.
- `addons/main/` — the SQF side (CBA-macro layout, mirrors `arma3-dynops`'s `addons/main`).
  `fnc_pushGroup.sqf` builds one `group:upsert` payload per group (readiness,
  waypoints, and its full tracked-unit list together) and sends it unless it is unchanged
  since the last send (dirty-only pushes: `../docs/adapter.md`'s Push model).
  `fnc_schedulePush.sqf` is the per-frame handler that calls it: rather than pushing every
  group in the same frame, it spreads one push cycle (every eligible group, once) evenly
  across `TICK` seconds, and drains `fnc_requestGroupPush.sqf`'s dirty-group queue first
  each frame, for an event-driven push that can't wait for its regular turn (currently: a
  kill, so readiness and membership reflect it within a frame instead of up to `TICK`
  seconds later); those pushes pass `_force` so the unchanged check can't skip them.

## `group:upsert`'s shape

```
["group:upsert", [id, side, [fuel, ammo, health], hasTask, waypoints, units]] call FUNC(call);
```

`units` is `[[id, kind, type, posASL, dir, velocity, damage], ...]` -- no `group_id` per
unit: the server fills it in from the containing group
(`StateCache::upsert_group_with_units`), so an embedded unit can't disagree with which
group it's actually in. It's the group's *complete* current membership: any unit
previously reported under this group but missing from this call's list is dropped, and
`fnc_pushGroup.sqf` builds it from `units _group` filtered to `alive` (a unit that died
this tick is dropped here too, not upserted one last time -- `unit:remove` already
reported it immediately). A crewed vehicle's whole crew maps to one `VEHICLE`/`HELICOPTER`/
`PLANE` entry (see `fnc_vehicleOwner.sqf`), not one entry per crewman. `XEH_postInit.sqf`'s
`EntityKilled` handler re-derives a killed crew member's vehicle's owner and dirties that
group too, since a kill can hand the vehicle to another group's surviving crew.

## Configuration

`start`'s address comes from SQF (`GVAR(listenAddress)`, default `127.0.0.1:50051`) unless
the `MINERVA_LISTEN_ADDR` environment variable is set and non-empty, which overrides it. A
dedicated server has no mission hook to set the SQF variable, so its systemd unit sets the
env var instead. `resolve_listen_addr` in `src/lib.rs` holds the rule; see
`../docs/adapter.md` for the user-facing description.

## The `minerva-server` dependency

A path dependency on `../server` through the root `[workspace.dependencies]`, so server
changes are picked up with no version bump.

## Testing

- `cargo test -p minerva-arma3` — unit tests (`src/lib.rs`, `src/convert.rs`) plus
  `tests/extension.rs`, which drives the extension through `arma_rs`'s `testing::Extension`
  (i.e. exactly the string-marshalled calls SQF would make) and, for the gRPC-facing tests,
  a real tonic client against the server `start` actually binds. `tests/listen_addr_env.rs`
  is a separate binary with a single test because it sets `MINERVA_LISTEN_ADDR`
  process-wide.
- `cargo bench -p minerva-arma3` — `benches/extension.rs`, the full `group:upsert` call path
  (marshalling + `StateCache` write) for a 12-man-squad-plus-vehicle group, since that's the largest
  single call `fnc_pushGroup.sqf` makes, at most once per group per its turn in the push cycle.
- `cargo llvm-cov --workspace --all-features --ignore-filename-regex 'server/src/gen/'` —
  coverage with the same flags as CI, which posts a summary to the job summary.
- `hemtt check` (from this directory) — lints the SQF (`.hemtt/lints.toml`) and rapifies the
  addon config; run before opening a PR.
- `hemtt release` (from this directory) — builds `releases/minerva-latest.zip` with an
  `@minerva` top-level folder. It bundles `minerva_x64.dll`/`.so` if they sit in this
  directory (CI copies the release builds there; locally `cp ../target/release/libminerva.so
  minerva_x64.so`) and silently skips a missing one. Both files are gitignored.

## Gotchas

- `unwrap`/`expect` are denied by clippy lints in `Cargo.toml`: a panic in the extension kills the
  Arma process, so return an `Err` to SQF instead. Tests use small `expect` helper functions.
- Tests that call `start` read `MINERVA_LISTEN_ADDR` from the environment; unset it in your
  shell if you export it for a local dedicated server, or those tests will bind it.
- `arma_rs::testing::Extension::call` args are the same strings a real `callExtension`
  call would send: string arguments must be quoted (`"\"g1\""`, not `"g1"`), everything
  else (numbers, arrays, bools) doesn't need to be.
- `arma_rs::Value` doesn't implement `IntoArma` directly — wrap it with
  `Value::direct(value)` when passing a pre-built `Value` to `callback_data`/as a command
  return value.
- `arma_rs::Extension`/`Context` hold an `Rc` internally, so they're `!Send`. Don't
  `tokio::spawn`/`spawn_blocking` anything that captures them — call their (sync, and in
  `callback_handler`'s case, blocking) methods directly in the current task instead; see
  `tests/extension.rs`'s `send_command_acked_via_callback_and_ack` for the pattern (spawn
  only the tonic client call, block the current task on `callback_handler`).
- `arma-rs` parses a `String` argument leniently in debug builds (which `cargo test` is) and
  strictly in release builds: an unquoted value such as the `any` SQF makes of a nil is
  accepted by the former and fails with retcode 30 (first argument) in the latter. Never
  trust `cargo test` alone for marshalling; `validate_id` in `src/lib.rs` rejects an empty or
  `any` id in both. `BIS_fnc_netId` takes the object or group itself (`_unit call
  BIS_fnc_netId`); `[_unit] call BIS_fnc_netId` returns nil, which is what that failure was.
- SQF-side diagnostics use `diag_log` with a `[minerva]` prefix, not `BIS_fnc_error`: a Linux
  dedicated server has no `.rpt`, and `BIS_fnc_error`'s output isn't reliably in its console,
  which once left a failing push entirely silent. `fnc_call.sqf` logs every failed call and
  returns `nil`, so a caller that needs to know checks `isNil` on the result
  (`fnc_pushGroup.sqf` returns it as is, or `true` when it skipped an unchanged group;
  `fnc_schedulePush.sqf` counts the nils per cycle and logs the `true`s as skipped).
  Keep new log lines quiet in the steady state (log changes, not every frame) and list them
  in `../docs/adapter.md`'s Logging section.

## Docs

- `../docs/adapter.md` — this adapter's specific behavior within the protocol contract
  (`../docs/contract.md`): configuration, what it reports for fields the contract leaves up
  to the server, and which commands it supports.
- `../docs/in-game-testing.md` — runbook for an actual in-game smoke test against a real
  Arma 3 client.
