# minerva-arma3 adapter behavior

[`contract.md`](contract.md) defines what any client may rely on. This document covers only
what's specific to the Arma 3 adapter (`arma3/`) -- a client should not assume another
`minerva-server` engine plugin behaves the same way on any of these points.

## Configuration

- The gRPC listen address defaults to `127.0.0.1:50051`. SQF can change it by setting
  `GVAR(listenAddress)` before `postInit` runs (`arma3/addons/main/XEH_postInit.sqf`).
- The `MINERVA_LISTEN_ADDR` environment variable of the Arma process overrides whatever SQF
  passes to `start`. A dedicated server has no mission hook to set `GVAR(listenAddress)`, so
  this is how a service manager (e.g. a systemd unit) configures it. An empty value counts as
  unset; a non-empty but unparsable value makes `start` fail rather than fall back to SQF's
  address. `start` returns the address actually bound, so `:0` reports the real port, and the
  addon logs `[minerva] gRPC listening on <addr>` once it has started (see Logging).

## Logging

The addon writes every line with `diag_log`, prefixed `[minerva]`: to the `.rpt` file where
there is one, otherwise to the server console (journald for a Linux dedicated server under
systemd; `journalctl -u <unit> | grep '\[minerva\]'`). It stays quiet while things work:

| Line | When |
| --- | --- |
| `[minerva] gRPC listening on <addr>` | Once, after `start` succeeded. |
| `[minerva] init: world <worldName>, size <worldSize>, sided groups: <n>` | Once, at `postInit` after `sim:info`. Groups spawned later aren't counted, so a low `<n>` here is not an error. |
| `[minerva] push cycle: <n> groups (of <total> total)` | When a push cycle's group count differs from the last one logged, and always for the first cycle. `<n>` is the west/east/independent/civilian groups that get pushed; `<total>` is every group, including logic groups (modules, headless clients). `0` means nothing is pushed. |
| `[minerva] push cycle: <n> group pushes failed` | After a cycle in which `<n>` (non-zero) `group:upsert` calls failed, only if `<n>` differs from the previous cycle's count. Nothing is logged for a clean cycle, so recovery is silent. Pushes made out of band after a kill aren't counted. |
| `[minerva] call '<function>' failed: errcode <e> (<name>), retcode <r>, result: <text>, args: <args>` | Every failed extension call, the cause behind the failure count above. `<args>` is the call's arguments as SQF serialized them (`str`), cut off at 400 characters. Not throttled: a call that always fails logs once per attempt, i.e. up to once per group per second for `group:upsert`. |

`<e>` is the engine's error code: `101` (`SYNTAX_ERROR_WRONG_PARAMS_SIZE`), `102`
(`SYNTAX_ERROR_WRONG_PARAMS_TYPE`) and `201` (`PARAMS_ERROR_TOO_MANY_ARGS`) are named, any
other non-zero code is shown as `unmapped`, and `301` is not treated as a failure. `<r>` is the
extension's return code (from `arma-rs`): `1` unknown command, `2N` wrong number of arguments
(`N` were sent), `3N` argument number `N+1` couldn't be parsed, `9` the command returned an
error, in which case `<text>` is its message (e.g. `minerva: not started`, `unknown side: LOGIC`).
A failed call returns `nil` to SQF.

## Coordinates and time

- `SimulationInfo.world_size` reports Arma's `worldSize` for both `x_meters` and
  `y_meters` -- the current adapter doesn't distinguish a non-square map.
- `simulation_start_sim_time` and `SimulationStateUpdate.simulation_time` are derived
  from Arma's `date` array, which has no seconds component, so both are truncated to the
  minute. `simulation_start_real_time` is not: it's `SystemTime::now()` at `sim:info`
  time, wall-clock, full second precision.

## Readiness and loadout

- `ammo_state` is always `1`: there's no generic "ammo fraction" command for a mixed
  group, so no ammo model exists yet.
- `fuel_state` averages `fuel` over tracked vehicles (`1` if there are none) and
  `health_state` averages `1 - damage` over every tracked unit (`1` if there are none); a
  wrecked vehicle with an unhurt crew pulls the group's health down, not just its fuel.
- `UnitState.loadout` is never populated.

## Commands

- `DefendZone` and `Support` always return `COMMAND_RESULT_FAILURE` ("not implemented").
- `Move`/`SearchAndDestroy`/`Patrol` place a normal `"MOVE"`/`"SAD"` waypoint. A
  `CommandTarget` with no `z` is placed at the surface (`addWaypoint`'s ordinary AGL
  interpretation, `0` meaning the ground at that x/y); a present `z` is honored as an
  exact ASL altitude via `addWaypoint`'s `placementRadius = -1` (see
  `fnc_executeCommand.sqf`).

## Membership and units

- `ListLocations` is always empty: nothing in this adapter ever calls `set_locations`.
- Factions (`SimulationInfo.factions`) are empty unless mission code sets `GVAR(factions)`
  before `postInit` runs (there's no generic way to enumerate "the factions in play" from
  SQF alone).
- A crewed vehicle is reported as a single unit belonging to one deterministic owning
  group (the group of the first real crew seat -- driver, then commander/gunner/turrets),
  not one unit per crew member and not shared between the crew's group and any group
  riding as passengers.
