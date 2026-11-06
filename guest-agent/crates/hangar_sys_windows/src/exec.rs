//! Programs `hangar exec` starts: in a pseudo console for `-t`, and in a job, so a close ends the
//! program with everything it started.

use std::{
    fs::File,
    io,
    os::windows::io::{FromRawHandle, RawHandle},
    path::Path,
    ptr::{null, null_mut},
};

use windows_sys::Win32::{
    Foundation::{HANDLE, INVALID_HANDLE_VALUE, WAIT_OBJECT_0},
    System::{
        Console::{COORD, ClosePseudoConsole, CreatePseudoConsole, HPCON, ResizePseudoConsole},
        JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_BREAKAWAY_OK,
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
            SetInformationJobObject, TerminateJobObject,
        },
        Pipes::CreatePipe,
        Threading::{
            CREATE_SUSPENDED, CREATE_UNICODE_ENVIRONMENT, CreateProcessW,
            DeleteProcThreadAttributeList, EXTENDED_STARTUPINFO_PRESENT, GetExitCodeProcess,
            INFINITE, InitializeProcThreadAttributeList, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            PROCESS_INFORMATION, ResumeThread, STARTUPINFOEXW, TerminateProcess,
            UpdateProcThreadAttribute, WaitForSingleObject,
        },
    },
};

use super::{Handle, UserEnvironment, check, hresult, size_u32, wide};

/// What a program in a job exits with when the job is ended.
const ENDED_EXIT: u32 = 1;

/// The programs a command started, ended together.
#[derive(Debug)]
pub struct Job(Handle);

// SAFETY: a job is a kernel handle, which any thread may use.
unsafe impl Send for Job {}
// SAFETY: as above.
unsafe impl Sync for Job {}

impl Job {
    pub fn new() -> io::Result<Job> {
        // SAFETY: no security attributes and no name.
        let job = unsafe { CreateJobObjectW(null(), null()) };
        if job.is_null() {
            return Err(io::Error::last_os_error());
        }

        let job = Job(Handle(job));
        job.allow_breakaway()?;
        Ok(job)
    }

    /// `update` starts the agent's installer with `CREATE_BREAKAWAY_FROM_JOB` when it can't go
    /// through UAC, so the end of the command that started it doesn't end the install too. Windows
    /// takes this flag only in the extended limits; the basic ones fail with `ERROR_INVALID_PARAMETER`.
    fn allow_breakaway(&self) -> io::Result<()> {
        // SAFETY: the structure is plain C data, and all zeros is a valid value for it.
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_BREAKAWAY_OK;

        // SAFETY: the job handle is open: `Job` owns it until drop; `limits` is a local of the
        // size passed with it, and the class says which structure it is.
        check(unsafe {
            SetInformationJobObject(
                self.0.0,
                JobObjectExtendedLimitInformation,
                (&raw const limits).cast(),
                size_u32::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>(),
            )
        })
    }

    /// `process` is a handle the caller keeps open for the call, such as a `Child`'s.
    pub fn add(&self, process: RawHandle) -> io::Result<()> {
        // SAFETY: both handles are open for the call.
        check(unsafe { AssignProcessToJobObject(self.0.0, process.cast()) })
    }

    /// Ends every program in the job; one that already ended is no matter.
    pub fn end(&self) {
        // SAFETY: the job handle is open: `Job` owns it until drop.
        unsafe { TerminateJobObject(self.0.0, ENDED_EXIT) };
    }
}

/// A started program, to wait for.
#[derive(Debug)]
pub struct Process(Handle);

// SAFETY: a process handle may be waited on from any thread.
unsafe impl Send for Process {}

impl Process {
    /// For a program that never ran, before it is in a job.
    fn end(&self) {
        // SAFETY: the process handle is open: `Process` owns it until drop.
        unsafe { TerminateProcess(self.0.0, ENDED_EXIT) };
    }

    pub fn wait(&self) -> io::Result<u32> {
        // SAFETY: the process handle is open: `Process` owns it until drop.
        if unsafe { WaitForSingleObject(self.0.0, INFINITE) } != WAIT_OBJECT_0 {
            return Err(io::Error::last_os_error());
        }
        let mut code = 0;
        // SAFETY: as above; `code` is a local.
        check(unsafe { GetExitCodeProcess(self.0.0, &raw mut code) })?;
        Ok(code)
    }
}

/// The pseudo console a `-t` program runs in; closing it ends the program's output.
#[derive(Debug)]
pub struct PseudoConsole(HPCON);

// SAFETY: a pseudo console handle may be resized and closed from any thread.
unsafe impl Send for PseudoConsole {}
// SAFETY: as above.
unsafe impl Sync for PseudoConsole {}

impl PseudoConsole {
    pub fn resize(&self, columns: u16, rows: u16) -> io::Result<()> {
        // SAFETY: the console is open: `PseudoConsole` owns it until drop.
        let result = unsafe { ResizePseudoConsole(self.0, size(columns, rows)) };
        hresult(result)
    }
}

impl Drop for PseudoConsole {
    fn drop(&mut self) {
        // SAFETY: the console was made by `CreatePseudoConsole`, nothing else closes it, and it is
        // closed exactly once, here.
        unsafe { ClosePseudoConsole(self.0) };
    }
}

/// A program running in a pseudo console: write its input, read what it shows.
#[derive(Debug)]
pub struct ProgramInConsole {
    pub process: Process,
    pub console: PseudoConsole,
    pub input: File,
    pub output: File,
}

/// Starts `command_line` in `folder` in a new pseudo console of `columns` × `rows`, in `job`. It
/// starts suspended and is put in the job before it runs, so nothing it starts escapes the job.
pub fn start_in_console(
    command_line: &str,
    folder: &Path,
    environment: &UserEnvironment,
    columns: u16,
    rows: u16,
    job: &Job,
) -> io::Result<ProgramInConsole> {
    let (console_input, input) = pipe()?;
    let (output, console_output) = pipe()?;
    let mut console: HPCON = 0;
    // SAFETY: both pipe ends are open; `console` is a local the call writes.
    let made = unsafe {
        CreatePseudoConsole(
            size(columns, rows),
            console_input.0,
            console_output.0,
            0,
            &raw mut console,
        )
    };
    hresult(made)?;
    let console = PseudoConsole(console);
    // The console has its own copies; the program's end of the pipes must close with it.
    drop(console_input);
    drop(console_output);

    let created = create_suspended(command_line, folder, environment, &console)?;
    if let Err(error) = job.add(created.process.0.0.cast()) {
        created.process.end();
        return Err(error);
    }
    // SAFETY: `created.thread` is the new program's main thread, open until `Handle` drops it.
    if unsafe { ResumeThread(created.thread.0) } == u32::MAX {
        let error = io::Error::last_os_error();
        job.end();
        return Err(error);
    }

    Ok(ProgramInConsole {
        process: created.process,
        console,
        input: file(input),
        output: file(output),
    })
}

struct Created {
    process: Process,
    thread: Handle,
}

fn create_suspended(
    command_line: &str,
    folder: &Path,
    environment: &UserEnvironment,
    console: &PseudoConsole,
) -> io::Result<Created> {
    let mut attributes = AttributeList::with_console(console)?;
    // SAFETY: `STARTUPINFOEXW` is plain C data, and all zeros is a valid value for it.
    let mut startup: STARTUPINFOEXW = unsafe { std::mem::zeroed() };
    startup.StartupInfo.cb = size_u32::<STARTUPINFOEXW>();
    startup.lpAttributeList = attributes.list();

    let mut line = wide(command_line);
    let folder = wide(folder);
    // SAFETY: `PROCESS_INFORMATION` is plain C data, and all zeros is a valid value for it.
    let mut created: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };
    // SAFETY: `line` is NUL-terminated and writable, as CreateProcessW wants; `folder` is
    // NUL-terminated; the environment block, `startup` and its attribute list and `created` outlive
    // the call. No handles are inherited: the pseudo console carries the program's input and
    // output.
    check(unsafe {
        CreateProcessW(
            null(),
            line.as_mut_ptr(),
            null(),
            null(),
            0,
            EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT,
            environment.block(),
            folder.as_ptr(),
            &raw const startup.StartupInfo,
            &raw mut created,
        )
    })?;

    Ok(Created {
        process: Process(Handle(created.hProcess)),
        thread: Handle(created.hThread),
    })
}

/// A process attribute list that holds one pseudo console.
struct AttributeList(Vec<u8>);

impl AttributeList {
    fn with_console(console: &PseudoConsole) -> io::Result<AttributeList> {
        let mut length = 0;
        // SAFETY: a null list asks for the size it needs; the call then fails by design.
        unsafe { InitializeProcThreadAttributeList(null_mut(), 1, 0, &raw mut length) };
        let mut list = AttributeList(vec![0; length]);
        // SAFETY: the buffer has the size the first call asked for.
        check(unsafe { InitializeProcThreadAttributeList(list.list(), 1, 0, &raw mut length) })?;

        // SAFETY: the list was initialized above; the value is the console handle itself, as the
        // pseudo console attribute expects, and the console outlives the program's creation.
        check(unsafe {
            UpdateProcThreadAttribute(
                list.list(),
                0,
                PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE as usize,
                console.0 as *const core::ffi::c_void,
                size_of::<HPCON>(),
                null_mut(),
                null(),
            )
        })?;
        Ok(list)
    }

    fn list(&mut self) -> *mut core::ffi::c_void {
        self.0.as_mut_ptr().cast()
    }
}

impl Drop for AttributeList {
    fn drop(&mut self) {
        // SAFETY: the list was initialized in `with_console` and is deleted once, here.
        unsafe { DeleteProcThreadAttributeList(self.list()) };
    }
}

/// A new anonymous pipe: its read end, then its write end.
fn pipe() -> io::Result<(Handle, Handle)> {
    let mut read: HANDLE = INVALID_HANDLE_VALUE;
    let mut write: HANDLE = INVALID_HANDLE_VALUE;
    // SAFETY: both handles are locals the call writes; no security attributes, default size.
    check(unsafe { CreatePipe(&raw mut read, &raw mut write, null(), 0) })?;
    Ok((Handle(read), Handle(write)))
}

fn file(handle: Handle) -> File {
    let raw = handle.0;
    std::mem::forget(handle);
    // SAFETY: `raw` is an open pipe handle that `handle` owned; ownership moves to the `File`.
    unsafe { File::from_raw_handle(raw.cast()) }
}

fn size(columns: u16, rows: u16) -> COORD {
    COORD {
        X: i16::try_from(columns).unwrap_or(i16::MAX),
        Y: i16::try_from(rows).unwrap_or(i16::MAX),
    }
}
