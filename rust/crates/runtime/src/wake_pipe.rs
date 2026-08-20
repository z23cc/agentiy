use nix::fcntl::{FcntlArg, FdFlag, OFlag, fcntl};
use nix::unistd::{dup, pipe};
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::OwnedFd;
use std::sync::Mutex;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WakeSignal {
    Written,
    AlreadyPending,
}

#[derive(Debug)]
pub enum WakePipeError {
    Io(io::Error),
    Closed,
}

impl std::fmt::Display for WakePipeError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "wake pipe I/O failed: {error}"),
            Self::Closed => formatter.write_str("wake pipe is closed"),
        }
    }
}

impl std::error::Error for WakePipeError {}

impl From<io::Error> for WakePipeError {
    fn from(value: io::Error) -> Self {
        Self::Io(value)
    }
}

struct PipeState {
    read: Option<File>,
    write: Option<File>,
}

pub struct WakePipe {
    state: Mutex<PipeState>,
}

impl WakePipe {
    pub fn new() -> Result<Self, WakePipeError> {
        let (read, write) = pipe()
            .map_err(|errno| WakePipeError::Io(io::Error::from_raw_os_error(errno as i32)))?;
        for fd in [&read, &write] {
            fcntl(fd, FcntlArg::F_SETFL(OFlag::O_NONBLOCK))
                .map_err(|errno| WakePipeError::Io(io::Error::from_raw_os_error(errno as i32)))?;
            fcntl(fd, FcntlArg::F_SETFD(FdFlag::FD_CLOEXEC))
                .map_err(|errno| WakePipeError::Io(io::Error::from_raw_os_error(errno as i32)))?;
        }
        Ok(Self {
            state: Mutex::new(PipeState {
                read: Some(File::from(read)),
                write: Some(File::from(write)),
            }),
        })
    }

    pub fn duplicate_read_fd(&self) -> Result<OwnedFd, WakePipeError> {
        let state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let read = state.read.as_ref().ok_or(WakePipeError::Closed)?;
        dup(read).map_err(|errno| WakePipeError::Io(io::Error::from_raw_os_error(errno as i32)))
    }

    pub fn signal(&self) -> Result<WakeSignal, WakePipeError> {
        let state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let mut write = state.write.as_ref().ok_or(WakePipeError::Closed)?;
        match write.write(&[1]) {
            Ok(_) => Ok(WakeSignal::Written),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                Ok(WakeSignal::AlreadyPending)
            }
            Err(error) => Err(WakePipeError::Io(error)),
        }
    }

    pub fn drain_canonical(&self) -> Result<usize, WakePipeError> {
        let state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let mut read = state.read.as_ref().ok_or(WakePipeError::Closed)?;
        drain_reader(&mut read)
    }

    pub fn drain_duplicate(read_fd: OwnedFd) -> Result<(OwnedFd, usize), WakePipeError> {
        let mut file = File::from(read_fd);
        let count = drain_reader(&mut file)?;
        Ok((file.into(), count))
    }

    pub fn close(&self) -> bool {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let was_open = state.read.is_some() || state.write.is_some();
        state.read.take();
        state.write.take();
        was_open
    }

    pub fn is_closed(&self) -> bool {
        let state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        state.read.is_none() && state.write.is_none()
    }
}

fn drain_reader<R: Read>(reader: &mut R) -> Result<usize, WakePipeError> {
    let mut total = 0;
    let mut buffer = [0_u8; 256];
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => return Ok(total),
            Ok(count) => total += count,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(total),
            Err(error) => return Err(WakePipeError::Io(error)),
        }
    }
}
