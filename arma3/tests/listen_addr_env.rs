//! `MINERVA_LISTEN_ADDR` mutates process-global state, so this lives in its
//! own test binary (one process, one test) instead of `extension.rs`, where
//! it would race every other test's `start` call.

use arma_rs::testing::Extension;
use minerva::init;

const ENV: &str = "MINERVA_LISTEN_ADDR";

fn quoted(addr: &str) -> Vec<String> {
    vec![format!("\"{addr}\"")]
}

/// Sets the override, runs `start` with `sqf_addr` on a fresh extension and
/// stops it again, returning `start`'s `(result, code)`.
///
/// The server is stopped (which joins its thread) before returning so that no
/// thread other than the test harness's is alive at the next `set_var`.
fn start_with_env(env: Option<&str>, sqf_addr: &str) -> (String, i32) {
    // SAFETY: this is the only test in the binary, and every server started by
    // an earlier call has been stopped and joined, so no other thread can be
    // reading or writing the environment while we change it.
    unsafe {
        match env {
            Some(value) => std::env::set_var(ENV, value),
            None => std::env::remove_var(ENV),
        }
    }
    let extension: Extension = init().testing();
    let (result, code) = extension.call("start", Some(quoted(sqf_addr)));
    let (_, stop_code) = extension.call("stop", None);
    assert_eq!(stop_code, 0);
    (result, code)
}

#[test]
fn start_honours_listen_addr_env() {
    // An invalid SQF address can only succeed if the override replaced it, and
    // a failure names whichever address `start` actually tried.
    let (bound, code) = start_with_env(Some("127.0.0.1:0"), "not-an-address");
    assert_eq!(code, 0, "override must replace the SQF address: {bound}");
    assert!(bound.starts_with("127.0.0.1:"), "{bound}");
    assert_ne!(bound, "127.0.0.1:0", "must report the port actually bound");

    let (error, code) = start_with_env(Some("bad-override"), "127.0.0.1:0");
    assert_ne!(code, 0, "a bad override must not fall back to SQF");
    assert!(error.contains("bad-override"), "{error}");

    // Empty counts as unset: the SQF address is tried, not the empty string.
    let (error, code) = start_with_env(Some(""), "not-an-address");
    assert_ne!(code, 0);
    assert!(error.contains("not-an-address"), "{error}");

    let (_, code) = start_with_env(Some(""), "127.0.0.1:0");
    assert_eq!(code, 0, "empty override must use the SQF address");

    let (_, code) = start_with_env(None, "127.0.0.1:0");
    assert_eq!(code, 0, "unset override must use the SQF address");
}
