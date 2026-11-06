use super::*;

#[test]
fn the_line_matches_what_the_mac_reads() {
    let memory = Memory { total: 8, used: 3 };

    let text = line(memory, None, 7);

    assert_eq!(
        text,
        "{\"memory\":{\"total\":8,\"used\":3},\"version\":7}\n"
    );
}

#[test]
fn a_linux_line_says_whether_there_is_a_screen() {
    let memory = Memory { total: 8, used: 3 };

    let without = line(memory, Some(false), 12);

    assert_eq!(
        without,
        "{\"memory\":{\"total\":8,\"used\":3},\"screen\":false,\"version\":12}\n"
    );
}

#[test]
fn a_used_count_above_the_total_reads_as_all_of_it() {
    let overshoot = Memory::new(8, 9);
    let without_memory = Memory::new(0, 1);

    assert_eq!(overshoot, Memory::new(8, 8));
    assert_eq!(without_memory, None);
}

#[test]
fn memory_comes_from_total_and_available() {
    let meminfo =
        "MemTotal:        8131200 kB\nMemFree:          100 kB\nMemAvailable:    6131200 kB\n";
    let expected = Memory {
        total: 8_131_200 * 1024,
        used: 2_000_000 * 1024,
    };

    let memory = memory_from_meminfo(meminfo.as_bytes());

    assert_eq!(memory, Some(expected));
}

#[test]
fn broken_meminfo_gives_nothing() {
    let cases = [
        ("MemTotal: 0 kB\nMemAvailable: 0 kB\n", None),
        ("MemTotal: lots kB\nMemAvailable: 1 kB\n", None),
        (
            "MemTotal: 18446744073709551615 kB\nMemAvailable: 1 kB\n",
            None,
        ),
        ("MemAvailable: 1 kB\n", None),
        (
            "MemTotal: 4 kB\nMemAvailable: 9 kB\n",
            Some(Memory {
                total: 4096,
                used: 0,
            }),
        ),
    ];

    for (meminfo, expected) in cases {
        assert_eq!(
            memory_from_meminfo(meminfo.as_bytes()),
            expected,
            "{meminfo}"
        );
    }
}

#[test]
fn versions_are_plain_numbers() {
    assert_eq!(parse_version(None), 0);
    assert_eq!(parse_version(Some("7")), 7);
    assert_eq!(parse_version(Some("120")), 120);
}
