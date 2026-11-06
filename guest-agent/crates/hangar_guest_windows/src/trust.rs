//! Brings the guest to the host's `trust` state: Hangar's CA among the machine's trusted roots,
//! and its placeholder variables among the machine's environment variables. What is already in
//! place is left alone.

use std::io;

use hangar_error::Error;
use hangar_host_commands::TrustState;
use hangar_sys_windows::{
    self as sys,
    certificates::{Certificate, RootStore},
};

use super::service::note_in_log;

const ENVIRONMENT_KEY: &str = r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment";
/// The names Hangar set, separated by spaces, so the ones the host drops are deleted again.
const HANGAR_KEY: &str = r"SOFTWARE\Hangar";
const NAMES_VALUE: &str = "HangarSecretNames";

pub(crate) fn reconcile(state: &TrustState) {
    if let Err(error) = put_ca(state.ca_der.as_deref()) {
        note_in_log(&Error::step(
            "put Hangar's CA among the trusted roots",
            error,
        ));
    }
    if let Err(error) = put_variables(&state.variables) {
        note_in_log(&Error::step("set Hangar's environment variables", error));
    }
}

/// Every certificate named like Hangar's goes, including the CAs of VMs this one was cloned from.
fn put_ca(wanted: Option<&[u8]>) -> io::Result<()> {
    let store = RootStore::open()?;
    let installed: Vec<Certificate> = store
        .certificates()
        .into_iter()
        .filter(|certificate| hangar_host_commands::is_hangar_ca_name(&certificate.common_name()))
        .collect();

    let is_in_place = match wanted {
        Some(der) => matches!(installed.as_slice(), [only] if only.der() == der),
        None => installed.is_empty(),
    };
    if is_in_place {
        return Ok(());
    }

    for certificate in &installed {
        store.delete(certificate)?;
    }
    if let Some(der) = wanted {
        store.add(der)?;
    }
    Ok(())
}

/// The record lists every name before its value is set, so no value Hangar sets is ever missing
/// from it.
fn put_variables(wanted: &[(String, String)]) -> io::Result<()> {
    let recorded = sys::registry_text(HANGAR_KEY, NAMES_VALUE).unwrap_or_default();
    let recorded_names: Vec<&str> = recorded
        .split(' ')
        .filter(|name| !name.is_empty())
        .collect();
    let wanted_names: Vec<&str> = wanted.iter().map(|(name, _)| name.as_str()).collect();

    let removed_names = names_missing_from(&recorded_names, &wanted_names);
    let changed = variables_not_set(wanted);
    if removed_names.is_empty() && changed.is_empty() {
        return Ok(());
    }

    let added_names = names_missing_from(&wanted_names, &recorded_names);
    let old_and_new_names = [recorded_names.as_slice(), added_names.as_slice()].concat();
    record_names(&old_and_new_names)?;

    for (name, value) in changed {
        sys::set_registry_text(ENVIRONMENT_KEY, name, value)?;
    }
    for name in removed_names {
        sys::delete_registry_value(ENVIRONMENT_KEY, name)?;
    }
    record_names(&wanted_names)?;

    sys::announce_environment_change();
    Ok(())
}

/// The names in `names` that `others` doesn't have.
fn names_missing_from<'a>(names: &[&'a str], others: &[&str]) -> Vec<&'a str> {
    names
        .iter()
        .filter(|name| !others.contains(name))
        .copied()
        .collect()
}

fn variables_not_set(wanted: &[(String, String)]) -> Vec<&(String, String)> {
    wanted
        .iter()
        .filter(|(name, value)| sys::registry_text(ENVIRONMENT_KEY, name).as_deref() != Some(value))
        .collect()
}

fn record_names(names: &[&str]) -> io::Result<()> {
    sys::set_registry_text(HANGAR_KEY, NAMES_VALUE, &names.join(" "))
}
