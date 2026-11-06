//! Display adapters through the setup API: whether one has started, and turning a device off.

use std::{
    ffi::OsString,
    io,
    os::windows::ffi::OsStringExt,
    ptr::{null, null_mut},
};

use windows_sys::Win32::{
    Devices::{
        DeviceAndDriverInstallation::{
            DICS_DISABLE, DICS_FLAG_GLOBAL, DIF_PROPERTYCHANGE, DIGCF_PRESENT, DN_STARTED,
            GUID_DEVCLASS_DISPLAY, HDEVINFO, SP_CLASSINSTALL_HEADER, SP_DEVINFO_DATA,
            SP_PROPCHANGE_PARAMS, SetupDiCallClassInstaller, SetupDiCreateDeviceInfoList,
            SetupDiDestroyDeviceInfoList, SetupDiEnumDeviceInfo, SetupDiGetClassDevsW,
            SetupDiGetDeviceInstanceIdW, SetupDiGetDevicePropertyW, SetupDiOpenDeviceInfoW,
            SetupDiSetClassInstallParamsW,
        },
        Properties::{
            DEVPKEY_Device_DevNodeStatus, DEVPKEY_Device_ProblemCode, DEVPROP_TYPE_UINT32,
        },
    },
    Foundation::{DEVPROPKEY, INVALID_HANDLE_VALUE},
};

use super::{check, size_u32, wide};

const INSTANCE_ID_LENGTH: usize = 512;

struct DeviceList(HDEVINFO);

impl DeviceList {
    fn present_displays() -> Option<DeviceList> {
        // SAFETY: the class id is a valid constant; no enumerator and no parent window.
        let list = unsafe {
            SetupDiGetClassDevsW(&GUID_DEVCLASS_DISPLAY, null(), null_mut(), DIGCF_PRESENT)
        };

        if list == INVALID_HANDLE_VALUE as HDEVINFO {
            return None;
        }

        Some(DeviceList(list))
    }

    fn empty() -> io::Result<DeviceList> {
        // SAFETY: no class and no parent window make an empty list.
        let list = unsafe { SetupDiCreateDeviceInfoList(null(), null_mut()) };

        if list == INVALID_HANDLE_VALUE as HDEVINFO {
            return Err(io::Error::last_os_error());
        }

        Ok(DeviceList(list))
    }

    fn device(&self, index: u32) -> Option<SP_DEVINFO_DATA> {
        let mut device = device_data();
        // SAFETY: `self` keeps the list open until it drops; `device` is a local whose size
        // `device_data` set.
        let found = unsafe { SetupDiEnumDeviceInfo(self.0, index, &raw mut device) } != 0;

        if !found {
            return None;
        }

        Some(device)
    }

    fn instance_id(&self, device: &SP_DEVINFO_DATA) -> Option<String> {
        let mut buffer = [0u16; INSTANCE_ID_LENGTH];
        let capacity = u32::try_from(buffer.len()).ok()?;

        // SAFETY: `self` keeps the list open until it drops, and callers pass a `device` from it;
        // `buffer` is a local of `capacity` units; the required size isn't asked for.
        let ok = unsafe {
            SetupDiGetDeviceInstanceIdW(self.0, device, buffer.as_mut_ptr(), capacity, null_mut())
        };

        if ok == 0 {
            return None;
        }

        let length = buffer
            .iter()
            .position(|&unit| unit == 0)
            .unwrap_or(buffer.len());
        let id = OsString::from_wide(&buffer[..length]);
        Some(id.to_string_lossy().to_uppercase())
    }

    fn has_started(&self, device: &SP_DEVINFO_DATA) -> bool {
        let started = self
            .number(device, &DEVPKEY_Device_DevNodeStatus)
            .is_some_and(|status| status & DN_STARTED != 0);
        let no_problem = self.number(device, &DEVPKEY_Device_ProblemCode) == Some(0);
        started && no_problem
    }

    fn number(&self, device: &SP_DEVINFO_DATA, key: &DEVPROPKEY) -> Option<u32> {
        let mut kind = 0;
        let mut value = 0u32;

        // SAFETY: `self` keeps the list open until it drops, and callers pass a `device` from it;
        // `value` is a local `u32` of the size passed; a property of another type or size fails
        // instead of writing.
        let ok = unsafe {
            SetupDiGetDevicePropertyW(
                self.0,
                device,
                key,
                &raw mut kind,
                (&raw mut value).cast(),
                size_u32::<u32>(),
                null_mut(),
                0,
            )
        };

        if ok == 0 || kind != DEVPROP_TYPE_UINT32 {
            return None;
        }

        Some(value)
    }
}

impl Drop for DeviceList {
    fn drop(&mut self) {
        // SAFETY: only `present_displays` and `empty` make a `DeviceList`, from a list the setup
        // API made; it is destroyed exactly once, here.
        unsafe { SetupDiDestroyDeviceInfoList(self.0) };
    }
}

pub fn display_adapter_started(prefix: &str) -> bool {
    let Some(list) = DeviceList::present_displays() else {
        return false;
    };

    let prefix = prefix.to_uppercase();
    let mut index = 0;

    while let Some(device) = list.device(index) {
        index += 1;
        let matches = list
            .instance_id(&device)
            .is_some_and(|id| id.starts_with(&prefix));
        if matches && list.has_started(&device) {
            return true;
        }
    }

    false
}

pub fn disable_device(instance: &str) -> io::Result<()> {
    let list = DeviceList::empty()?;
    let instance = wide(instance);
    let mut device = device_data();
    // SAFETY: `list` stays open until it drops, `instance` is NUL-terminated (`wide`) and
    // `device` is a local whose size `device_data` set; no parent window and no flags.
    check(unsafe {
        SetupDiOpenDeviceInfoW(list.0, instance.as_ptr(), null_mut(), 0, &raw mut device)
    })?;

    let change = SP_PROPCHANGE_PARAMS {
        ClassInstallHeader: SP_CLASSINSTALL_HEADER {
            cbSize: size_u32::<SP_CLASSINSTALL_HEADER>(),
            InstallFunction: DIF_PROPERTYCHANGE,
        },
        StateChange: DICS_DISABLE,
        Scope: DICS_FLAG_GLOBAL,
        HwProfile: 0,
    };

    // SAFETY: `device` was opened into `list` above, and the header starts the local
    // `SP_PROPCHANGE_PARAMS` whose size is passed with it.
    check(unsafe {
        SetupDiSetClassInstallParamsW(
            list.0,
            &raw const device,
            &raw const change.ClassInstallHeader,
            size_u32::<SP_PROPCHANGE_PARAMS>(),
        )
    })?;

    // SAFETY: `list` stays open until it drops, and `device` was opened into it above, with the
    // parameters just set.
    check(unsafe { SetupDiCallClassInstaller(DIF_PROPERTYCHANGE, list.0, &raw const device) })
}

fn device_data() -> SP_DEVINFO_DATA {
    // SAFETY: `SP_DEVINFO_DATA` is plain data for which all-zero bytes are a valid value.
    let mut data: SP_DEVINFO_DATA = unsafe { std::mem::zeroed() };
    data.cbSize = size_u32::<SP_DEVINFO_DATA>();
    data
}
