//! Which paths the root service accepts as virtio ports; pure, so the tests run on any host.

use std::path::Path;

/// Takes a canonical path: a port is a device directly in /dev named `vport…`.
pub(crate) fn is_virtio_port_path(path: &Path) -> bool {
    let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
        return false;
    };

    path.parent() == Some(Path::new("/dev")) && name.starts_with("vport")
}

#[cfg(test)]
#[path = "port_path_test.rs"]
mod tests;
