//! `MINERVA_LISTEN_ADDR` mutates process-global state, so this lives in its
//! own test binary (one process, one test) instead of `extension.rs`, where
//! it would race every other test's `start` call.

use minerva::init;

/// A syntactically invalid address: `start` can only succeed with it if the
/// environment override replaced it.
const UNUSABLE_SQF_ADDR: &str = "\"not-an-address\"";

#[test]
fn start_honours_listen_addr_env() {
    // SAFETY: this is the only test in the binary, so nothing else reads or
    // writes the environment while it runs.
    unsafe { std::env::set_var("MINERVA_LISTEN_ADDR", "") };
    let (result, code) = init()
        .testing()
        .call("start", Some(vec![UNUSABLE_SQF_ADDR.to_string()]));
    assert_ne!(code, 0, "empty override must fall back to the SQF address");
    assert!(result.contains("invalid address"), "{result}");

    // SAFETY: see above.
    unsafe { std::env::set_var("MINERVA_LISTEN_ADDR", "127.0.0.1:0") };
    let extension = init().testing();
    let (bound, code) = extension.call("start", Some(vec![UNUSABLE_SQF_ADDR.to_string()]));
    assert_eq!(code, 0, "override must replace the SQF address: {bound}");
    assert!(bound.starts_with("127.0.0.1:"), "{bound}");
    assert_ne!(bound, "127.0.0.1:0", "must report the port actually bound");

    // SAFETY: see above.
    unsafe { std::env::set_var("MINERVA_LISTEN_ADDR", "not-an-address") };
    let (result, code) = init()
        .testing()
        .call("start", Some(vec!["\"127.0.0.1:0\"".to_string()]));
    assert_ne!(
        code, 0,
        "a bad override must not fall back to the SQF address"
    );
    assert!(result.contains("invalid address"), "{result}");

    // SAFETY: see above.
    unsafe { std::env::remove_var("MINERVA_LISTEN_ADDR") };
    let (_, code) = init()
        .testing()
        .call("start", Some(vec!["\"127.0.0.1:0\"".to_string()]));
    assert_eq!(code, 0, "unset override must use the SQF address");
}
