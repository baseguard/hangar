use super::*;

#[test]
fn a_vport_device_in_dev_is_a_port() {
    assert!(is_virtio_port_path(Path::new("/dev/vport1p1")));
}

#[test]
fn other_paths_are_not_ports() {
    for path in [
        "/dev/tmp/vport1p1",
        "/tmp/vport1p1",
        "/dev/ttyS0",
        "/dev",
        "/",
    ] {
        assert!(!is_virtio_port_path(Path::new(path)), "{path}");
    }
}
