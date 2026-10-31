#include "script_component.hpp"

if (!isServer) exitWith {};

if (isNil QGVAR(listenAddress)) then {
    GVAR(listenAddress) = "127.0.0.1:50051";
};
// Mission code can set this (before postInit runs) to report real factions;
// there's no generic way to enumerate "the factions in play" from SQF alone.
if (isNil QGVAR(factions)) then {
    GVAR(factions) = [];
};
// fnc_schedulePush's push cycle: the (snapshotted) groups still due a push
// this cycle, and where in it the cursor is.
GVAR(cycle) = [];
GVAR(cycleCursor) = 0;
// Diagnostics state: failed pushes in the current cycle and in the one
// before it, and the group count last logged (-1 so the first cycle always
// logs one).
GVAR(cycleFailures) = 0;
GVAR(lastCycleFailures) = 0;
GVAR(lastLoggedCycleCount) = -1;
// Groups fnc_requestGroupPush has marked for an out-of-band push on the
// very next frame.
GVAR(dirtyGroups) = [];
// What fnc_pushGroup last sent per group: group netId -> [payload, time].
// Lets it skip a group:upsert whose payload hasn't changed.
GVAR(lastPayload) = createHashMap;
// fnc_schedulePush's push stats for the current STATS_INTERVAL window:
// group:upsert calls made and avoided, finished cycles, and the window's start.
GVAR(statsPushed) = 0;
GVAR(statsSkipped) = 0;
GVAR(statsCycles) = 0;
GVAR(statsWindowStart) = diag_tickTime;

// The extension reports the address it actually bound, which
// MINERVA_LISTEN_ADDR can make differ from GVAR(listenAddress). Log it so an
// operator can see where the server is listening; nil means start failed and
// fnc_call already reported why.
private _listening = ["start", [GVAR(listenAddress)]] call FUNC(call);
if (!isNil "_listening") then {
    diag_log format ["[minerva] gRPC listening on %1", _listening];
};
["reset"] call FUNC(call);
["sim:info", [worldName, [worldSize, worldSize], GVAR(factions), date]] call FUNC(call);
// Groups may not exist yet at postInit, so a low count here isn't an error;
// fnc_schedulePush logs the count it actually pushes.
diag_log format [
    "[minerva] init: world %1, size %2, sided groups: %3",
    worldName, worldSize, count (allGroups select {(side _x) in [west, east, independent, civilian]})
];

addMissionEventHandler ["ExtensionCallback", FUNC(onCallback)];

addMissionEventHandler ["EntityKilled", {
    params ["_unit"];
    if (_unit isKindOf "Man" || {_unit isKindOf "AllVehicles"}) then {
        ["unit:remove", [_unit call BIS_fnc_netId]] call FUNC(call);
        // Readiness (health/fuel averages) and membership shouldn't wait
        // up to TICK seconds to reflect a kill.
        [group _unit] call FUNC(requestGroupPush);
        // A dead real-seat occupant can hand the vehicle's record to
        // another group's surviving crew (fnc_vehicleOwner, recomputed
        // here now that _unit is already dead); that group's own regular
        // turn is up to TICK away, so it needs the same out-of-band push
        // as the group that just lost the vehicle.
        private _vehicle = objectParent _unit;
        if (!isNull _vehicle) then {
            [[_vehicle] call FUNC(vehicleOwner)] call FUNC(requestGroupPush);
        };
    };
}];

addMissionEventHandler ["EntityDeleted", {
    params ["_entity"];
    if (_entity isKindOf "Man" || {_entity isKindOf "AllVehicles"}) then {
        ["unit:remove", [_entity call BIS_fnc_netId]] call FUNC(call);
    };
}];

addMissionEventHandler ["GroupDeleted", {
    params ["_group"];
    private _groupId = _group call BIS_fnc_netId;
    // Mainly so the map doesn't grow with every group ever created. It also
    // keeps a netId handed to a later group from being compared against this
    // group's payload, which could delay that group's first push by up to
    // FULL_REFRESH if the two payloads happened to be identical.
    GVAR(lastPayload) deleteAt _groupId;
    ["group:remove", [_groupId]] call FUNC(call);
}];

addMissionEventHandler ["Ended", {["reset"] call FUNC(call);}];
addMissionEventHandler ["MPEnded", {["reset"] call FUNC(call);}];

[FUNC(schedulePush), 0, []] call CBA_fnc_addPerFrameHandler;
