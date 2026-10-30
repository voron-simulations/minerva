# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

Minerva Protocol defines the gRPC contract between a "server" (a plugin embedded in a
military simulation engine, e.g. Arma 3) and "clients" that read simulation state and
send commands to units/groups. It is protobuf-only: no generated code is committed to
this repo. Consumers (e.g. `minerva-server`) generate their own bindings, typically via
`buf generate` against the published BSR module.

## Layout

All `.proto` files live under `minerva/v1/`, package `minerva.v1`:

- `common.proto` — `Side`, `Position`, `Orientation`, `Velocity`, `Faction`.
- `unit.proto` — `Unit`, `UnitState`, `HealthState`, `UnitCategory`, `UnitService`.
- `group.proto` — `Group`, `GroupReadiness`, `GroupService`.
- `location.proto` — `Location`, `Capability`, `LocationService`.
- `simulation.proto` — `WorldSize`, `SimulationInfo`, `SimulationStateUpdate`, `SimulationService`.
- `commands.proto` — `CommandTarget` (x/y plus optional ASL z, for a command's
  destination), per-command messages (`MoveCommand`, `SearchAndDestroyCommand`, ...),
  `CommandService.SendCommand` (single RPC, oneof over command types).
- `waypoint.proto`, `weather.proto`, `loadout.proto` — supporting types.

Units: positions are in meters, `z` is altitude above sea level (ASL). Directions
(`Orientation.direction`) are compass degrees (0 = north, clockwise). Wind fields on
`Weather` are reported as-is from the simulation (radians from east, counterclockwise).

`Group.units` is the group's full current membership (`Unit.group_id` always equals the
containing group's `id`); `UnitService.ListUnits`/`GetUnit` read the same state and never
disagree with it. See `docs/contract.md` for the full wire contract.

## Working with the protos

This repo uses [buf](https://buf.build) — there is no `protoc` step and no build script.

- `buf lint` — check style (config: `buf.yaml`, `STANDARD` lint rules).
- `buf format -w` — format in place; `buf format --diff --exit-code` to check only.
- `buf build` — verify the module compiles.
- `buf breaking --against '.git#branch=main'` — check for breaking changes against `main`.

Run all three (lint, format check, build) before opening a PR; CI (`bufbuild/buf-action`)
runs the same checks, plus a breaking-change check against the PR base branch by
default. The `buf skip breaking` PR label skips that check for an intentional break;
adding or removing the label reruns CI.

## Publishing (BSR)

The module is `buf.build/voron-simulations/minerva`, public, default label `main`. CI
pushes a new commit to BSR automatically on every push to `main` (`buf push`, using the
`BUF_TOKEN` repository secret). A consumer may pin a specific BSR commit in its
`buf.gen.yaml` input so protocol changes only take effect when it explicitly bumps the
pin, or track the `main` label directly to regenerate against the latest push (as
`minerva-server` does — its CI fails its "no diff" check whenever `main` has moved ahead
of its committed generated code, which is the forcing function to update).

## Compatibility policy

- Prefer additive changes (new fields, new RPCs, new messages) — these are non-breaking
  and safe to publish directly to `main`.
- Breaking changes (removing/renaming fields or RPCs, changing field numbers or types)
  are allowed but must be called out explicitly in the PR description, since every
  downstream consumer (`minerva-server` and, transitively, `minerva-arma3`) has to bump
  its pinned commit and update accordingly. Apply the `buf skip breaking` PR label
  only for a deliberate, documented break.
