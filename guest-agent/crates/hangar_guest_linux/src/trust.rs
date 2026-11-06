//! Brings the guest to the host's `trust` state: Hangar's CA in the system's trust store, and its
//! placeholder variables in every login shell and user session. Unchanged files are left alone.

use std::process::{Command, Stdio};

use hangar_error::Error;
use hangar_fs::{Dir, Owner};
use hangar_host_commands::TrustState;

use crate::trust_files::{environment_file, profile_script};

const PROFILE_FOLDER: &str = "/etc/profile.d";
const PROFILE_FILE: &str = "hangar-secrets.sh";
const ENVIRONMENT_FOLDER: &str = "/etc/environment.d";
const ENVIRONMENT_FILE: &str = "90-hangar-secrets.conf";
const FILE_MODE: u32 = 0o644;

/// Where a distribution takes extra CAs from, and the tool that adds them to its bundles.
struct TrustStore {
    folder: &'static str,
    file: &'static str,
    tool: &'static str,
    tool_arguments: &'static [&'static str],
}

const DEBIAN_STORE: TrustStore = TrustStore {
    folder: "/usr/local/share/ca-certificates",
    file: "hangar-secrets.crt",
    tool: "update-ca-certificates",
    tool_arguments: &[],
};

const FEDORA_STORE: TrustStore = TrustStore {
    folder: "/etc/pki/ca-trust/source/anchors",
    file: "hangar-secrets.pem",
    tool: "update-ca-trust",
    tool_arguments: &["extract"],
};

impl TrustStore {
    fn ca_path(&self) -> String {
        format!("{}/{}", self.folder, self.file)
    }
}

pub(crate) fn reconcile(state: &TrustState) {
    let store = trust_store();
    hangar_error::note_failure(
        "the guest trusts the CA it trusted before",
        put_ca(store, state),
    );

    let ca_path = store.map(TrustStore::ca_path);
    let variables = state.variables_with_node_ca(ca_path.as_deref());

    let profile = profile_script(&variables);
    hangar_error::note_failure(
        "login shells keep the variables they had",
        put_file(PROFILE_FOLDER, PROFILE_FILE, profile.as_deref()),
    );

    let environment = environment_file(&variables);
    hangar_error::note_failure(
        "user sessions keep the variables they had",
        put_file(ENVIRONMENT_FOLDER, ENVIRONMENT_FILE, environment.as_deref()),
    );
}

/// Debian and Ubuntu, then Fedora and RHEL; `None` on a guest with neither.
fn trust_store() -> Option<&'static TrustStore> {
    [&DEBIAN_STORE, &FEDORA_STORE]
        .into_iter()
        .find(|store| std::path::Path::new(store.folder).is_dir())
}

/// The tool runs only when the CA file changed, since the host sends the state at every start.
fn put_ca(store: Option<&TrustStore>, state: &TrustState) -> hangar_error::Result<()> {
    let Some(store) = store else {
        if state.ca_der.is_none() {
            return Ok(());
        }
        return Err(Error::Plain(
            "This guest has no folder for extra CAs that Hangar knows.",
        ));
    };

    let pem = state.ca_pem();
    if put_file(store.folder, store.file, pem.as_deref())? {
        update_trust_store(store)?;
    }
    Ok(())
}

fn update_trust_store(store: &TrustStore) -> hangar_error::Result<()> {
    let tool = crate::system_program(store.tool);
    let status = Command::new(&tool)
        .args(store.tool_arguments)
        .stdin(Stdio::null())
        .status();
    hangar_error::check_exit(tool, status)
}

/// Root-owned and replaced in one step; `true` when the file changed. A missing folder is fine
/// when there is nothing to put in it.
fn put_file(folder: &str, name: &str, wanted: Option<&str>) -> hangar_error::Result<bool> {
    let path = format!("{folder}/{name}");
    let dir = match Dir::open(folder) {
        Ok(dir) => dir,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound && wanted.is_none() => {
            return Ok(false);
        }
        Err(error) => return Err(Error::file("open", folder, error)),
    };

    dir.update_file(name, wanted.map(str::as_bytes), FILE_MODE, Owner::Root)
        .map_err(|error| Error::file("update", path, error))
}
