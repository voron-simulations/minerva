#include "script_component.hpp"
/*
    Executes a command dispatched by minerva-server, decoded from a
    "minerva"/"command" ExtensionCallback payload: [id, type, groupId, ...],
    see ArmaCommandSink (minerva-arma3's src/sink.rs) for the exact shape
    per type. Always ends with a command:ack.

    Handles move, search_and_destroy and patrol, the kinds ArmaCommandSink
    declares as supported; the server rejects every other kind before it gets
    here, so the default case below is only a safety net. Add a case here and
    the kind to the sink's list together.
*/
params ["_id", "_type", "_groupId"];
private _extra = _this select [3];

private _fnc_ack = {
    params ["_id", "_ok", ["_reason", ""]];
    ["command:ack", [_id, _ok, _reason]] call FUNC(call);
};

private _group = _groupId call BIS_fnc_groupFromNetId;
if (isNull _group) exitWith {
    [_id, false, "unknown group"] call _fnc_ack;
};

// Index 0 is the group's implicit start waypoint, which fnc_pushGroup never
// reports. It is left in place: if it were deleted, the first waypoint a
// command adds would become index 0 and be hidden from every state push.
private _fnc_clearWaypoints = {
    params ["_grp"];
    for "_i" from (count waypoints _grp) - 1 to 1 step -1 do {
        deleteWaypoint [_grp, _i];
    };
};

// Called once a command has added its waypoints. The engine's current
// waypoint may still point at the start waypoint, or at an index the clear
// removed, so the group is pointed at the command's first waypoint (index 1)
// explicitly instead of relying on where the engine left it. Nothing to do
// when the command added no waypoint at all.
private _fnc_startRoute = {
    params ["_grp"];
    if ((count waypoints _grp) > 1) then {
        _grp setCurrentWaypoint [_grp, 1];
    };
};

// A CommandTarget's z arrives as [] (absent) or [z] (present), since
// callback payloads have no null (see sink.rs's command_target_values).
// Returns [position, placementRadius] for addWaypoint: absent z is ground-
// placed, using addWaypoint's normal AGL interpretation (0 = the surface at
// this x/y, the only altitude a 2D client can know); a present z is an
// exact altitude, honored as ASL (matching getPosASL) via placementRadius
// -1, for a target that isn't ground-level (e.g. an aircraft's CAP
// station).
private _fnc_target = {
    params ["_x", "_y", "_zArr"];
    if (_zArr isEqualTo []) exitWith {[[_x, _y, 0], 0]};
    [[_x, _y, _zArr select 0], -1]
};

switch (_type) do {
    case "move": {
        _extra params ["_x", "_y", "_zArr"];
        private _target = [_x, _y, _zArr] call _fnc_target;
        _target params ["_pos", "_radius"];
        [_group] call _fnc_clearWaypoints;
        (_group addWaypoint [_pos, _radius]) setWaypointType "MOVE";
        [_group] call _fnc_startRoute;
        [_id, true] call _fnc_ack;
    };
    case "search_and_destroy": {
        _extra params ["_x", "_y", "_zArr"];
        private _target = [_x, _y, _zArr] call _fnc_target;
        _target params ["_pos", "_radius"];
        [_group] call _fnc_clearWaypoints;
        (_group addWaypoint [_pos, _radius]) setWaypointType "SAD";
        [_group] call _fnc_startRoute;
        [_id, true] call _fnc_ack;
    };
    case "patrol": {
        _extra params ["_loop"];
        private _coords = _extra select [1];
        private _count = (count _coords) / 3;
        [_group] call _fnc_clearWaypoints;
        private _firstPos = [];
        private _firstRadius = 0;
        for "_i" from 0 to (_count - 1) do {
            (_coords select [_i * 3, 3]) params ["_x", "_y", "_zArr"];
            private _target = [_x, _y, _zArr] call _fnc_target;
            _target params ["_pos", "_radius"];
            if (_i == 0) then { _firstPos = _pos; _firstRadius = _radius; };
            (_group addWaypoint [_pos, _radius]) setWaypointType "MOVE";
        };
        if (_loop) then {
            // CYCLE redirects the group to the *nearest* waypoint in the
            // list; placed at the last point it would coincide with the
            // final MOVE just added above, so "nearest" resolves to that
            // same waypoint and the patrol degenerates into looping on just
            // the last point. Placing it at the first point instead (with
            // the same radius, so a ground-placed first point isn't
            // reinterpreted as ASL) makes it resolve to waypoint 1, the
            // first point (index 0 is the implicit start waypoint), so the
            // whole route repeats.
            (_group addWaypoint [_firstPos, _firstRadius]) setWaypointType "CYCLE";
        };
        [_group] call _fnc_startRoute;
        [_id, true] call _fnc_ack;
    };
    default {
        [_id, false, format ["unknown command type: %1", _type]] call _fnc_ack;
    };
};
