#include "script_component.hpp"
/*
    Added with delay 0 by XEH_postInit, so CBA runs this every frame (0
    means "as often as possible", not "once"). Spreads each period's full
    round of group pushes evenly across ~TICK seconds instead of pushing
    every group in the same frame -- which would land every group's
    callExtension cost in a single frame's budget on a mission with many
    groups -- and pushes any group marked dirty (see fnc_requestGroupPush)
    on the very next frame, ahead of its regular turn in the cycle.

    diag_tickTime is real (wall-clock) time, unaffected by time
    acceleration: TICK means "this often in real seconds", not simulation
    time, so pushing on simulation time would make the stagger -- and the
    push rate itself -- speed up or slow down with time acceleration.
*/

{
    if !(isNull _x) then {
        // Forced: a group is only marked dirty because something just
        // changed (a kill), so the unchanged check must not get to skip it.
        [_x, true] call FUNC(pushGroup);
    };
} forEach GVAR(dirtyGroups);
GVAR(dirtyGroups) = [];

if (GVAR(cycleCursor) >= count GVAR(cycle)) then {
    if (isNil QGVAR(cycleStart) || {diag_tickTime - GVAR(cycleStart) >= TICK}) then {
        // The cycle that just finished is reported here, before its counter
        // is reset. Only a change is logged: a push that fails every cycle
        // would otherwise repeat the same line once per TICK. fnc_call has
        // already logged each failure's cause.
        if (GVAR(cycleFailures) > 0 && {GVAR(cycleFailures) != GVAR(lastCycleFailures)}) then {
            diag_log format ["[minerva] push cycle: %1 group pushes failed", GVAR(cycleFailures)];
        };
        GVAR(lastCycleFailures) = GVAR(cycleFailures);
        GVAR(cycleFailures) = 0;

        // The same boundary closes the stats window, so it only ever holds
        // whole cycles. The first boundary has no finished cycle behind it.
        // Logged once per STATS_INTERVAL rather than per cycle: this line is
        // the measure of how many callExtension calls the unchanged check
        // saves, not an event.
        if (!isNil QGVAR(cycleStart)) then {
            GVAR(statsCycles) = GVAR(statsCycles) + 1;
        };
        if (diag_tickTime - GVAR(statsWindowStart) >= STATS_INTERVAL) then {
            diag_log format [
                "[minerva] push stats: %1 pushed, %2 skipped over %3 cycles",
                GVAR(statsPushed), GVAR(statsSkipped), GVAR(statsCycles)
            ];
            GVAR(statsPushed) = 0;
            GVAR(statsSkipped) = 0;
            GVAR(statsCycles) = 0;
            GVAR(statsWindowStart) = diag_tickTime;
        };

        private _allGroups = allGroups;
        GVAR(cycle) = _allGroups select {
            // sideLogic groups (modules, headless clients) have no
            // protocol side; publishing them only produces rejected group
            // upserts and orphaned units.
            (side _x) in [west, east, independent, civilian]
        };
        GVAR(cycleCursor) = 0;
        GVAR(cycleStart) = diag_tickTime;
        // A cycle with far fewer groups than the mission has (or none) is
        // the first thing to rule out when groups never show up server-side.
        if (count GVAR(cycle) != GVAR(lastLoggedCycleCount)) then {
            GVAR(lastLoggedCycleCount) = count GVAR(cycle);
            diag_log format ["[minerva] push cycle: %1 groups (of %2 total)", count GVAR(cycle), count _allGroups];
        };
        ["sim:state", [date, accTime, overcast, wind]] call FUNC(call);
    };
};

private _cycleCount = count GVAR(cycle);
if (GVAR(cycleCursor) < _cycleCount) then {
    private _elapsed = (diag_tickTime - GVAR(cycleStart)) min TICK;
    private _due = 0 max ceil (_cycleCount * _elapsed / TICK);
    while {GVAR(cycleCursor) < _due} do {
        private _group = GVAR(cycle) select GVAR(cycleCursor);
        if !(isNull _group) then {
            // pushGroup returns nil when its group:upsert failed and `true`
            // when it skipped the call as unchanged. Only the cycle's own
            // pushes are counted, not the out-of-band dirty ones, so the
            // counts are comparable to the cycle's group count.
            private _result = [_group] call FUNC(pushGroup);
            // Checked before _result is read: an undefined variable raises a
            // script error where the isNil string form does not.
            private _skipped = !isNil "_result" && {_result isEqualTo true};
            if (isNil "_result") then {
                GVAR(cycleFailures) = GVAR(cycleFailures) + 1;
            };
            // A failed push still made the extension call, so it is traffic.
            if (_skipped) then {
                GVAR(statsSkipped) = GVAR(statsSkipped) + 1;
            } else {
                GVAR(statsPushed) = GVAR(statsPushed) + 1;
            };
        };
        GVAR(cycleCursor) = GVAR(cycleCursor) + 1;
    };
};
