//! Whether the kernel drives a screen, from the names it lists in sysfs; pure, so the tests run on
//! any host.

/// A screen device is `card` (DRM) or `fb` (framebuffer) and a number; `card0-Virtual-1` and the
/// like are a card's outputs.
pub(crate) fn names_a_screen(name: &str) -> bool {
    let number = name
        .strip_prefix("card")
        .or_else(|| name.strip_prefix("fb"));
    number.is_some_and(|digits| {
        !digits.is_empty() && digits.bytes().all(|byte| byte.is_ascii_digit())
    })
}

#[cfg(test)]
#[path = "screen_test.rs"]
mod tests;
