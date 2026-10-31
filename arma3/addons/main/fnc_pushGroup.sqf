#include "script_component.hpp"
/*
    Pushes one group's (and its tracked units') current state into
    minerva-server via a single "group:upsert" call. Called once per group
    per push cycle by fnc_schedulePush, and again out of its regular turn
    when fnc_schedulePush drains the dirty queue fnc_requestGroupPush fills.

    The call is skipped when the payload equals the one last sent for this
    group and that was less than FULL_REFRESH seconds ago, since an idle group
    would otherwise cost one callExtension per TICK for nothing. `_force`
    bypasses the comparison, for pushes that exist because something just
    changed (a kill) and must reach the server whatever the comparison says.

    IDs are `x call BIS_fnc_netId`, stable across save/load and correct
    in both SP and MP (unlike the native `netId` command). It takes the
    object or group itself: wrapped in an array (`[x] call ...`) it returns
    nil, and a nil id is not a usable string argument for the extension.

    Returns `true` when the push was skipped as unchanged, otherwise the
    "group:upsert" call's result, which is nil if the call failed (fnc_call
    has already logged why). Skipping must not return nil, or
    fnc_schedulePush would count it as a failure; it tells the two apart by
    `true`, a boolean that callExtension's text result never is.
*/
params ["_group", ["_force", false, [false]]];

private _fnc_avg = {
    params ["_values", ["_default", 1]];
    if (_values isEqualTo []) exitWith {_default};
    private _sum = 0;
    {_sum = _sum + _x} forEach _values;
    _sum / (count _values);
};

// Rounds a number to the nearest 1/_perUnit. See QUANT_* in
// script_component.hpp for why the payload is quantized.
private _fnc_quantize = {
    params ["_value", "_perUnit"];
    (round (_value * _perUnit)) / _perUnit
};

// The same for each component of a vector. It is separate rather than built
// on _fnc_quantize because it runs for several vectors per unit per turn,
// and a scripted call per component would add up.
private _fnc_quantizeVec = {
    params ["_vec", "_perUnit"];
    _vec apply {(round (_x * _perUnit)) / _perUnit}
};

// A unit's damage, truncated toward 0 rather than rounded. A living unit can
// have damage up to 0.9999, which would round to 1 and report health 0, i.e.
// destroyed. Truncating keeps it at 0.999 at most. Group health below is
// derived from these same values, so it cannot reach 0 while any unit lives.
private _fnc_damage = {
    (floor ((damage _this) * QUANT_STATE_PER_UNIT)) / QUANT_STATE_PER_UNIT
};

private _groupId = _group call BIS_fnc_netId;

// Every group's `waypoints` starts with index 0, an implicit MOVE waypoint
// at its spawn position that exists even when nothing was ever placed.
// Reporting it would show each idle group as ordered to its own spawn point,
// so it is skipped here; `_allWaypoints` keeps it for the _hasTask count below.
private _allWaypoints = waypoints _group;
private _waypoints = [];
{
    if ((_x select 1) > 0) then {
        // waypointType already returns a plain string; str() would add a
        // second layer of quoting that never matches convert::waypoint_type_from_str.
        // waypointPosition is always AGL regardless of how the waypoint was
        // placed; convert to ASL to match the protocol's positions (and
        // fnc_executeCommand.sqf's addWaypoint, which expects ASL back).
        _waypoints pushBack [
            waypointType _x,
            [AGLToASL (waypointPosition _x), QUANT_POS_PER_M] call _fnc_quantizeVec
        ];
    };
} forEach _allWaypoints;

// No generic "ammo fraction" command exists for a mixed group; report
// full until a real ammo model is built.
private _ammoState = 1;
// Completed waypoints stay in `waypoints _group`; once the last one is
// done currentWaypoint moves one past the end, so only that means idle.
// currentWaypoint indexes the full list including the implicit index 0, so
// this compares against `_allWaypoints`, not the trimmed `_waypoints`.
private _hasTask = (currentWaypoint _group) < (count _allWaypoints);

// `units _group` gives the group's members, which for a crewed vehicle
// are the crew (persons), not the vehicle -- report the vehicle itself
// for members of its owning group, deduplicated (a tank's whole crew
// maps to one vehicle), and the person directly for everyone else.
private _trackedUnits = [];
{
    private _unit = _x;
    // A member who died this tick is dropped here (checked on the person,
    // before any vehicle substitution below) rather than upserted one last
    // time: EntityKilled already sent its immediate unit:remove, and a
    // dead unit lingers in `units _group` for a while after death, so
    // leaving it in would otherwise re-add it as a live-looking member on
    // this group's very next push (member replacement in
    // upsert_group_with_units only drops what this call doesn't list).
    // Checking the vehicle's own `alive` instead would miss exactly the
    // case this matters for: the vehicle hull can easily outlive its last
    // crew member, so a dead-crew vehicle would still look alive and stay
    // tracked -- other, still-living crew (if any) still vote it in via
    // their own iteration below, so a partially-dead crew doesn't lose it.
    if (alive _unit) then {
        if (isNull objectParent _unit) then {
            _trackedUnits pushBackUnique _unit;
        } else {
            private _vehicle = objectParent _unit;
            // A destroyed vehicle hull can still seat a survivor (an
            // armored wreck, an ejected-then-respawned-into-seat edge
            // case); substituting it in would immediately re-upsert a
            // damage==1 vehicle the very next push after EntityKilled
            // already removed it. Falling back to the living crew member
            // themselves keeps that member (and thus the group) reported.
            private _ownsVehicle = alive _vehicle && {([_vehicle] call FUNC(vehicleOwner)) isEqualTo _group};
            _trackedUnits pushBackUnique ([_unit, _vehicle] select _ownsVehicle);
        };
    };
} forEach (units _group);

// Fuel and health are over the same entities as the unit records below,
// so a wrecked tank with an unhurt crew doesn't report a healthy group,
// and a ride in another group's vehicle doesn't count as this one's fuel.
private _fuelState = [
    [_trackedUnits select {!(_x isKindOf "Man")} apply {fuel _x}] call _fnc_avg,
    QUANT_STATE_PER_UNIT
] call _fnc_quantize;
// Average damage defaults to 0 (not _fnc_avg's 1): a group with no tracked
// units has nothing damaged, and the default 1 would report it as health 0,
// i.e. destroyed, for a group that simply has no living members to average.
private _healthState = [
    1 - ([_trackedUnits apply {_x call _fnc_damage}, 0] call _fnc_avg),
    QUANT_STATE_PER_UNIT
] call _fnc_quantize;

private _units = _trackedUnits apply {
    private _unit = _x;
    // `Man` inherits from `AllVehicles` in Arma's class hierarchy, so it
    // must be excluded explicitly or every soldier is misclassified as
    // a generic VEHICLE below.
    private _kind = "INFANTRY";
    if (_unit isKindOf "Helicopter") then {
        _kind = "HELICOPTER";
    } else {
        if (_unit isKindOf "Plane") then {
            _kind = "PLANE";
        } else {
            if (_unit isKindOf "AllVehicles" && {!(_unit isKindOf "Man")}) then {_kind = "VEHICLE"};
        };
    };
    [
        _unit call BIS_fnc_netId,
        _kind,
        typeOf _unit,
        [getPosASL _unit, QUANT_POS_PER_M] call _fnc_quantizeVec,
        // Rounding can carry 359.96 up to 360, which is the same heading as 0;
        // wrap it so a unit facing north doesn't flip between the two.
        ([getDir _unit, QUANT_DIR_PER_DEG] call _fnc_quantize) mod 360,
        [velocity _unit, QUANT_VELOCITY_PER_MS] call _fnc_quantizeVec,
        _unit call _fnc_damage
    ]
};

private _args = [_groupId, str (side _group), [_fuelState, _ammoState, _healthState], _hasTask, _waypoints, _units];

private _last = GVAR(lastPayload) getOrDefault [_groupId, []];
private _unchanged = !_force
    && {_last isNotEqualTo []}
    && {(_last select 0) isEqualTo _args}
    && {diag_tickTime - (_last select 1) < FULL_REFRESH};
if (_unchanged) exitWith {true};

private _result = ["group:upsert", _args] call FUNC(call);
// Only a call that reached the server may update the record: after a failure
// the server still holds the older state, so the next turn must retry.
if (isNil "_result") exitWith {nil};
GVAR(lastPayload) set [_groupId, [_args, diag_tickTime]];
_result
