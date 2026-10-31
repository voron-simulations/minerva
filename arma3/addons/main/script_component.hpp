#include "\dw\minerva\addons\main\script_mod.hpp"

#define COMPONENT main
#define COMPONENT_BEAUTIFIED Main

// Seconds one push cycle spans: fnc_schedulePush gives every group a turn once per TICK.
#define TICK 1

// Longest a group goes without a group:upsert even when its payload is
// unchanged (fnc_pushGroup). The server's cache can diverge from what SQF
// remembers having sent (a reset, or a unit:remove for a unit the group still
// lists), and a periodic full push heals that without every such path having
// to invalidate the remembered payload. Longer values cut idle traffic
// further but leave a divergence visible for that much longer.
#define FULL_REFRESH 10

// Seconds between "push stats" log lines (fnc_schedulePush).
#define STATS_INTERVAL 60

// Resolution of the group:upsert payload (fnc_pushGroup), as steps per unit:
// rounding multiplies and divides by an exact integer, where a step such as
// 0.1 is not exactly representable as a float. Engine floats jitter far below
// anything a consumer can use -- an idle unit shows a velocity z of ~2e-6 and
// sub-millimetre position drift -- and that jitter would make every payload
// differ from the last, defeating the unchanged check. The quantized value is
// both compared and sent, so the server never sees precision the comparison
// ignored.
//
// Positions are 0.1 m, not finer, because that is all that survives anyway:
// SQF numbers are 32-bit floats, with 1-2 mm resolution at 8-32 km map
// coordinates, and callExtension's number-to-text keeps ~6 significant digits,
// so 0.01 m never reached the extension for coordinates of 10 km or more.
// A finer grid would also flicker whenever boundary jitter crossed a cell edge.
// 0.1 m
#define QUANT_POS_PER_M 10
// 0.1 degree
#define QUANT_DIR_PER_DEG 10
// 0.01 m/s
#define QUANT_VELOCITY_PER_MS 100
// 0.001 of fuel, health and damage
#define QUANT_STATE_PER_UNIT 1000
