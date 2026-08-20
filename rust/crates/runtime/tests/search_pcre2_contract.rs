use pcre2::bytes::RegexBuilder;

fn configured_builder(jit: bool) -> RegexBuilder {
    let mut builder = RegexBuilder::new();
    builder
        .utf(true)
        .ucp(true)
        .multi_line(true)
        .caseless(true)
        .jit(jit);
    builder
}

#[test]
fn pcre2_contract_arm64_bundled_static_and_jit_probe() {
    assert_eq!(std::env::consts::ARCH, "aarch64");
    assert_eq!(option_env!("PCRE2_SYS_STATIC"), Some("1"));

    let regex = configured_builder(true)
        .build(r"^\bångström\b$")
        .expect("the pinned bundled PCRE2 must compile the JIT probe");
    assert!(regex.is_match("ÅNGSTRÖM".as_bytes()).unwrap());
}

#[test]
fn pcre2_contract_inline_match_depth_and_heap_limits_are_accepted() {
    for prefix in [
        "(*LIMIT_MATCH=100000)",
        "(*LIMIT_DEPTH=1000)",
        "(*LIMIT_HEAP=4096)",
    ] {
        configured_builder(false)
            .build(&format!("{prefix}(?:a+)+$"))
            .unwrap_or_else(|error| panic!("limit control {prefix} was rejected: {error}"));
    }

    let limited = configured_builder(false)
        .build("(*LIMIT_MATCH=1)(?:a+)+$")
        .unwrap();
    let error = limited
        .is_match(format!("{}!", "a".repeat(128)).as_bytes())
        .expect_err("the explicit match limit must be enforced");
    assert!(
        error
            .to_string()
            .to_ascii_lowercase()
            .contains("match limit"),
        "unexpected limit error: {error}"
    );

    let depth_limited = configured_builder(false)
        .build("(*LIMIT_DEPTH=1)^(a(?1)?b)$")
        .unwrap();
    let error = depth_limited
        .is_match(b"aaaabbbb")
        .expect_err("the explicit depth limit must be enforced");
    assert!(
        error
            .to_string()
            .to_ascii_lowercase()
            .contains("depth limit"),
        "unexpected depth-limit error: {error}"
    );

    let heap_limited = configured_builder(false)
        .build("(*LIMIT_HEAP=1)^(?:(a+)+)+$")
        .unwrap();
    let error = heap_limited
        .is_match(format!("{}!", "a".repeat(4_096)).as_bytes())
        .expect_err("the explicit heap limit must be enforced");
    assert!(
        error
            .to_string()
            .to_ascii_lowercase()
            .contains("heap limit"),
        "unexpected heap-limit error: {error}"
    );
}
