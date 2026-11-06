use super::*;

#[test]
fn cards_and_framebuffers_are_screens() {
    assert!(names_a_screen("card0"));
    assert!(names_a_screen("card12"));
    assert!(names_a_screen("fb0"));
}

#[test]
fn outputs_and_other_entries_are_not() {
    assert!(!names_a_screen("card0-Virtual-1"));
    assert!(!names_a_screen("renderD128"));
    assert!(!names_a_screen("version"));
    assert!(!names_a_screen("card"));
    assert!(!names_a_screen("fbcon"));
}
