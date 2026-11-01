# AGENTS.md

## Project overview

This directory is the buf module `buf.build/voron-simulations/minerva`: the gRPC contract
between a "server" (a plugin embedded in a military simulation engine, e.g. Arma 3) and
"clients" that read simulation state and send commands to units/groups. It is protobuf-only:
no generated code lives here. `../server/` generates the Rust bindings (`buf generate`, see
`../server/AGENTS.md`); other consumers use the published BSR module.

## Layout

All `.proto` files live under `minerva/v1/`, package `minerva.v1`:

- `common.proto` — `Side`, `Position`, `Orientation`, `Velocity`, `Faction`.
- `unit.proto` — `Unit`, `UnitState`, `HealthState`, `UnitCategory`, `UnitService`.
- `group.proto` — `Group`, `GroupReadiness`, `GroupService`.
- `location.proto` — `Location`, `Capability`, `LocationService`.
- `simulation.proto` — `WorldSize`, `SimulationInfo` (including `supported_commands`),
  `SimulationStateUpdate`, `SimulationService`.
- `commands.proto` — `CommandTarget` (x/y plus optional ASL z, for a command's
  destination), per-command messages (`MoveCommand`, `SearchAndDestroyCommand`, ...),
  `CommandKind` (one value per command type, listed in `SimulationInfo.supported_commands`),
  `CommandService.SendCommand` (single RPC, oneof over command types).
- `waypoint.proto`, `weather.proto`, `loadout.proto` — supporting types.

Units: positions are in meters, `z` is altitude above sea level (ASL). Directions
(`Orientation.direction`) are compass degrees (0 = north, clockwise). Wind fields on
`Weather` are reported as-is from the simulation (radians from east, counterclockwise).

`Group.units` is the group's full current membership (`Unit.group_id` always equals the
containing group's `id`); `UnitService.ListUnits`/`GetUnit` read the same state and never
disagree with it. See `../docs/contract.md` for the full wire contract.

## Working with the protos

This module uses [buf](https://buf.build) — there is no `protoc` step and no build script.
Run these from this directory:

- `buf lint` — check style (config: `buf.yaml`, `STANDARD` lint rules).
- `buf format -w` — format in place; `buf format --diff --exit-code` to check only.
- `buf build` — verify the module compiles.
- `buf breaking --against '../.git#branch=main,subdir=proto'` — check for breaking changes against `main`.

Run lint, format check and build before opening a PR. After any change, regenerate the
server bindings (`cd ../server && buf generate`) and commit the diff; CI's `gen-check` job
fails otherwise.

The `proto.yml` workflow (`bufbuild/buf-action`, `input: proto`) runs the same checks plus a
breaking-change check against the PR base branch. The `buf skip breaking` PR label skips
that check for an intentional break; adding or removing the label reruns only this workflow,
which is why it is separate from `ci.yml`.

## Publishing (BSR)

The module is `buf.build/voron-simulations/minerva`, public, default label `main`. CI
pushes a new commit to BSR automatically on every push to `main` (`buf push`, using the
`BUF_TOKEN` repository secret). Clients outside this repo may pin a specific BSR commit so
protocol changes only take effect when they bump it. In-repo consumers never use the BSR:
`server/buf.gen.yaml` reads this directory.

## Compatibility policy

- Prefer additive changes (new fields, new RPCs, new messages) — these are non-breaking
  and safe to publish directly to `main`.
- Breaking changes (removing/renaming fields or RPCs, changing field numbers or types)
  are allowed but must be called out explicitly in the PR description, since external
  BSR consumers have to update. In-repo consumers (`server/`, `arma3/`) must be fixed in
  the same PR. Apply the `buf skip breaking` PR label only for a deliberate, documented break.
