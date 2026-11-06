//! The policy's facts, read from the system.

use std::{io, path::PathBuf};

use hangar_sys_windows::{self as sys, OpenedItem, channel::Channel};

use super::policy::{Account, ItemFacts, ItemKind, PipeFacts};

impl PipeFacts for Channel {
    fn client_process_id(&self) -> Option<u32> {
        Channel::client_process_id(self)
    }

    fn client_session_id(&self) -> Option<u32> {
        Channel::client_session_id(self)
    }

    fn console_session_id(&self) -> u32 {
        sys::channel::console_session_id()
    }

    fn program_of(&self, process: u32) -> Option<PathBuf> {
        sys::channel::program_of(process)
    }

    fn server_session_id(&self) -> Option<u32> {
        Channel::server_session_id(self)
    }

    fn server_owned_by(&self, account: Account) -> io::Result<bool> {
        self.owner_is(system_account(account))
    }
}

impl ItemFacts for OpenedItem {
    fn kind(&self) -> io::Result<ItemKind> {
        let kind = match OpenedItem::kind(self)? {
            sys::ItemKind::Folder => ItemKind::Folder,
            sys::ItemKind::Link => ItemKind::Link,
            sys::ItemKind::Other => ItemKind::Other,
        };
        Ok(kind)
    }

    fn owned_by(&self, account: Account) -> io::Result<bool> {
        self.is_owned_by(system_account(account))
    }
}

fn system_account(account: Account) -> sys::Account {
    match account {
        Account::System => sys::Account::System,
        Account::Administrators => sys::Account::Administrators,
    }
}
