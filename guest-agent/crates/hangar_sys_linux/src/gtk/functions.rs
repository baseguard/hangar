//! GTK's functions, found in its shared object when the first helper loads it.

use std::{
    ffi::{CStr, c_char, c_int, c_uint, c_ulong},
    marker::PhantomData,
    path::Path,
    sync::OnceLock,
    thread::{self, ThreadId},
};

use super::{AsyncReadyCallback, Callback, ClosureNotify, Library, Pointer, SourceFunction};

const GTK_LIBRARY: &CStr = c"libgtk-4.so.1";
/// Where arm64 distributions keep shared libraries: Debian and Ubuntu, Fedora, Arch and Alpine.
const LIBRARY_FOLDERS: [&str; 7] = [
    "/usr/lib/aarch64-linux-gnu",
    "/lib/aarch64-linux-gnu",
    "/usr/lib64",
    "/lib64",
    "/usr/lib",
    "/lib",
    "/usr/local/lib",
];

macro_rules! functions {
    ($($name:ident: fn($($argument:ty),*) $(-> $result:ty)?;)*) => {
        pub(crate) struct Functions {
            $(pub(crate) $name: unsafe extern "C" fn($($argument),*) $(-> $result)?,)*
        }

        impl Functions {
            fn find(library: SharedObject) -> Option<Functions> {
                Some(Functions {
                    $($name: {
                        let Some(address) = library.symbol(concat!(stringify!($name), "\0")) else {
                            MISSING_FUNCTION.get_or_init(|| stringify!($name));
                            return None;
                        };
                        // SAFETY: `address` is the exported C function `$name`; whoever edits
                        // the `functions!` list keeps each type equal to its C prototype.
                        unsafe {
                            std::mem::transmute::<
                                Pointer,
                                unsafe extern "C" fn($($argument),*) $(-> $result)?,
                            >(address)
                        }
                    },)*
                })
            }
        }
    };
}

functions! {
    gtk_application_new: fn(*const c_char, c_uint) -> Pointer;
    g_application_run: fn(Pointer, c_int, *mut *mut c_char) -> c_int;
    g_application_hold: fn(Pointer);
    g_signal_connect_data:
        fn(Pointer, *const c_char, Callback, Pointer, Option<ClosureNotify>, c_uint) -> c_ulong;
    g_timeout_add: fn(c_uint, SourceFunction, Pointer) -> c_uint;
    g_idle_add: fn(SourceFunction, Pointer) -> c_uint;
    gdk_display_get_default: fn() -> Pointer;
    gdk_set_allowed_backends: fn(*const c_char);
    g_free: fn(Pointer);
    g_object_ref: fn(Pointer) -> Pointer;
    g_object_unref: fn(Pointer);
    gdk_display_get_clipboard: fn(Pointer) -> Pointer;
    gdk_clipboard_is_local: fn(Pointer) -> c_int;
    gdk_clipboard_get_formats: fn(Pointer) -> Pointer;
    gdk_content_formats_contain_mime_type: fn(Pointer, *const c_char) -> c_int;
    gdk_clipboard_read_text_async: fn(Pointer, Pointer, AsyncReadyCallback, Pointer);
    gdk_clipboard_read_text_finish: fn(Pointer, Pointer, *mut Pointer) -> *mut c_char;
    gdk_clipboard_set_text: fn(Pointer, *const c_char);
}

struct Loaded {
    functions: Functions,
    /// The one thread allowed to call GTK.
    thread: ThreadId,
}

/// GTK can't be unloaded once it ran, so its function table lives as long as the process.
static LOADED: OnceLock<Option<Loaded>> = OnceLock::new();

/// The first function `load` didn't find, so an error can say which GTK is too old.
static MISSING_FUNCTION: OnceLock<&'static str> = OnceLock::new();

/// Set when GTK 4 opened but lacks a function the agent calls.
pub fn missing_function() -> Option<&'static str> {
    MISSING_FUNCTION.get().copied()
}

/// Looks for GTK 4's file without opening it, so root never runs GTK's code just to learn whether
/// the guest has a desktop.
pub fn is_installed() -> bool {
    let Ok(file_name) = GTK_LIBRARY.to_str() else {
        return false;
    };

    LIBRARY_FOLDERS
        .iter()
        .any(|folder| Path::new(folder).join(file_name).exists())
}

/// `None` without GTK 4, and on every thread but the first one that loaded it.
pub fn load() -> Option<Library> {
    let loaded = LOADED.get_or_init(open_gtk).as_ref()?;
    if loaded.thread != thread::current().id() {
        return None;
    }

    Some(Library {
        functions: &loaded.functions,
        loading_thread_only: PhantomData,
    })
}

fn open_gtk() -> Option<Loaded> {
    Some(Loaded {
        functions: Functions::find(SharedObject::open()?)?,
        thread: thread::current().id(),
    })
}

/// Never closed: GTK can't be unloaded once it ran.
#[derive(Clone, Copy)]
struct SharedObject(Pointer);

impl SharedObject {
    fn open() -> Option<SharedObject> {
        // SAFETY: `GTK_LIBRARY` is a NUL-terminated `CStr` literal; `dlopen` needs nothing else.
        let handle =
            unsafe { libc::dlopen(GTK_LIBRARY.as_ptr(), libc::RTLD_NOW | libc::RTLD_LOCAL) };
        if handle.is_null() {
            return None;
        }
        Some(SharedObject(handle))
    }

    fn symbol(self, name: &str) -> Option<Pointer> {
        let name = CStr::from_bytes_with_nul(name.as_bytes()).ok()?;

        // SAFETY: `self.0` comes from `SharedObject::open` and is never closed; `name` is a `CStr`.
        let address = unsafe { libc::dlsym(self.0, name.as_ptr()) };
        if address.is_null() {
            return None;
        }
        Some(address)
    }
}
