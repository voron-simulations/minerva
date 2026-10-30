# Minerva v1 contract

The protobuf definitions in [`minerva/v1`](../minerva/v1) are the wire contract.
This document records what any client and any server implementation may rely
on where a field or stream message alone does not convey it. It says nothing
about a specific adapter (e.g. Arma 3) — see that adapter's own docs for its
behavior within these rules.

## Coordinates and time

- Positions are map coordinates in meters, origin at the map's south-west
  corner: `x` increases east, `y` increases north. `SimulationInfo.world_size`
  gives the extents; the world spans `[0, x_meters] x [0, y_meters]`. A
  `Position.z` is altitude in meters above sea level (ASL).
- `Velocity` components and `Weather.wind_speed` are meters per second.
  `Orientation.direction` is a compass heading in degrees, clockwise from
  north. `Weather.wind_direction` is radians counterclockwise from east, as
  reported by the simulation.
- `simulation_start_sim_time` and `SimulationStateUpdate.simulation_time` are
  in-simulation Unix timestamps in seconds. `simulation_start_real_time` is a
  wall-clock Unix timestamp in seconds. `time_acceleration` is the
  simulation-time rate relative to real time, as reported by the engine.
  Neither timestamp is guaranteed finer than whole-minute precision.

## Command targets

`MoveCommand`, `SearchAndDestroyCommand`, `PatrolCommand`, and
`DefendZoneCommand` take a `CommandTarget` (x, y, optional z), not a
`Position`. x/y are always authoritative. An absent `z` means the server
places the target at the surface — the only thing a client without a terrain
model (e.g. a flat 2D map) can know. A present `z` is an exact altitude in
meters ASL, for a target that isn't ground-level (e.g. an aircraft's CAP
station).

## Readiness and loadout

`GroupReadiness.fuel_state`, `ammo_state`, and `health_state` are fractions:
0 is depleted or destroyed and 1 is full or undamaged. `HealthState.health` is
also 1 when undamaged and 0 when destroyed. A server is not required to model
every readiness dimension; an unmodeled one may always report 1.

`LoadoutState` and `Weapon` remain in the schema for consumers, but a server
may not populate `UnitState.loadout`. An absent loadout does not mean the
unit has no weapons.

## Filters and membership

An omitted `side` filter means all sides. A present filter matches the
group's `side`, the location's `owner`, or, for `ListUnits`, the side of the
unit's cached group. `ListUnits.group_id` filters by exact group ID; when both
filters are present, both must match. A unit without a cached group does not
match a `side` filter. An unknown `side` enum value returns `INVALID_ARGUMENT`.

`Group.units` is the group's full current membership; `Unit.group_id` always
equals the containing group's `id`. Membership may change arbitrarily between
updates, and a server may represent several simulation entities as a single
unit (e.g. a vehicle and its crew). `UnitService.ListUnits`/`GetUnit` read the
same underlying state and never disagree with a group's embedded `units`.

## Commands

`SendCommandRequest` selects one command. The server returns
`INVALID_ARGUMENT` for a missing command or required command data. Any
command may return `COMMAND_RESULT_FAILURE` with a reason, including for a
command type the server doesn't implement, or one targeting an unknown group.
For a dispatched command, `COMMAND_RESULT_SUCCESS` means the engine
acknowledged the command; it does not promise that the resulting task has
finished. An engine rejection, timeout, or reset also returns
`COMMAND_RESULT_FAILURE` with a reason.

## Streams and reset

`SubscribeGroupUpdates` starts with one `upserted` message per cached group
matching the optional `side` filter, followed by changes. `upserted` replaces
the client's view of that group, including its full unit set. `removed_id`
means the client should stop tracking that ID. Group removals are sent to all
subscribers because the ID does not carry a side. If a group changes side,
the server sends a removal for the old membership before an upsert for the
new one. A client may receive a removal for an ID it never tracked; it can
ignore that removal. There is no explicit end-of-snapshot marker, and there
is no update cadence, heartbeat, or minimum rate: an unchanged group may emit
nothing indefinitely, so a client must not infer liveness from timing.

`SubscribeSimulationUpdates` first sends the cached state if one exists,
then sends state changes. An absent `state` message signals a server reset
and clears the client's cached simulation state. On reset, the server also
sends `removed_id` for each cached group. New subscriptions after a reset
have no initial simulation state or groups until the server receives new
data. Neither stream has a reset generation or resumption cursor.

`GetSimulationInfo` returns `UNAVAILABLE` until the simulation has reported at
least once. Info may change across a reset, so a client should re-fetch it
rather than caching it indefinitely.

A subscriber that falls behind its bounded server-side buffer ends the
stream with `ABORTED`; the server does not skip events silently or send a
partial replacement. On `ABORTED` (or any stream error), the client discards
its cached groups or simulation state and resubscribes to rebuild them —
there is no lossless recovery within a single stream.
