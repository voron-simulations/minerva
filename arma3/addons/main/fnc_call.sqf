#include "script_component.hpp"

private _function = param [0, "echo", [""]];
private _args = param [1, [], [[]]];

// Call the extension and process the error codes
private _resultArray = "minerva" callExtension [_function, _args];

_resultArray params ["_result", "_retcode", "_errcode"];

// errcode 301 has always been accepted as success here; keep that.
private _failed = _retcode != 0 || {_errcode != 0 && {_errcode != 301}};

// Failures go to diag_log rather than BIS_fnc_error: a dedicated server has no
// RPT file on Linux and BIS_fnc_error's output isn't guaranteed to reach its
// console, which left a failing push completely silent. One line per failure,
// with everything needed to tell the causes apart: _retcode is the extension's
// (arma-rs: 1 unknown command, 2N wrong argument count N, 3N argument N+1
// unparsable, 9 the command returned an error), _errcode is the engine's.
if (_failed) exitWith {
    private _errName = switch (_errcode) do {
        case 101: {"SYNTAX_ERROR_WRONG_PARAMS_SIZE"};
        case 102: {"SYNTAX_ERROR_WRONG_PARAMS_TYPE"};
        case 201: {"PARAMS_ERROR_TOO_MANY_ARGS"};
        default {"unmapped"};
    };
    diag_log format [
        "[minerva] call '%1' failed: errcode %2 (%3), retcode %4, result: %5",
        _function, _errcode, _errName, _retcode, _result
    ];
    // On failure _result is error text, not a value; callers get nil rather
    // than something they could mistake for a result.
    nil
};

// Return the unwrapped call result without the error codes
_result;
