use crate::{
    AdmissionOutcome, AdmissionRequest, CancelOutcome, OperationId, OperationRegistry,
    OperationState, RegistryError, RuntimeConfig, RuntimeIdentity, SubscriptionError,
    SubscriptionHub, TerminalOutcome,
};
use std::collections::HashMap;
use std::fmt;
use std::future::Future;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};
use tokio::runtime::{Builder, Handle};
use tokio::sync::{Semaphore, watch};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LifecycleState {
    Starting,
    Running,
    ShuttingDown,
    Stopped,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ShutdownReceipt {
    pub already_started: bool,
    pub cancelled_operations: usize,
}

#[derive(Debug)]
pub enum RuntimeError {
    InvalidConfig(&'static str),
    Startup(String),
    Registry(RegistryError),
    Subscription(SubscriptionError),
    DataLaneSaturated,
    ShuttingDown,
}

impl fmt::Display for RuntimeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidConfig(message) => write!(formatter, "invalid runtime config: {message}"),
            Self::Startup(message) => write!(formatter, "runtime startup failed: {message}"),
            Self::Registry(error) => error.fmt(formatter),
            Self::Subscription(error) => error.fmt(formatter),
            Self::DataLaneSaturated => formatter.write_str("data lane is saturated"),
            Self::ShuttingDown => formatter.write_str("runtime is shutting down"),
        }
    }
}

impl std::error::Error for RuntimeError {}
impl From<RegistryError> for RuntimeError {
    fn from(value: RegistryError) -> Self {
        Self::Registry(value)
    }
}
impl From<SubscriptionError> for RuntimeError {
    fn from(value: SubscriptionError) -> Self {
        Self::Subscription(value)
    }
}

struct Shared {
    identity: RuntimeIdentity,
    registry: Arc<OperationRegistry>,
    subscriptions: Arc<SubscriptionHub>,
    lifecycle: Mutex<LifecycleState>,
    lifecycle_changed: Condvar,
    active_tasks: AtomicUsize,
    task_cancellations: Mutex<HashMap<OperationId, watch::Sender<bool>>>,
    shutdown_grace: Duration,
}

impl Shared {
    fn set_lifecycle(&self, lifecycle: LifecycleState) {
        *self
            .lifecycle
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = lifecycle;
        self.lifecycle_changed.notify_all();
    }

    fn lifecycle(&self) -> LifecycleState {
        *self
            .lifecycle
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

pub struct CoreRuntime {
    shared: Arc<Shared>,
    handle: Handle,
    shutdown: watch::Sender<bool>,
    data_slots: Arc<Semaphore>,
    thread: Mutex<Option<JoinHandle<()>>>,
}

impl CoreRuntime {
    pub fn new(config: RuntimeConfig, identity: RuntimeIdentity) -> Result<Self, RuntimeError> {
        // Must run before any `PanicGuard`-wrapped export can execute (see
        // `agentry_ffi::api::CoreRuntime::create`, which builds this runtime
        // before constructing its own `PanicGuard`): installing the hook
        // here, first, guarantees a panic on any later exported call is
        // captured into the forensics ring buffer, not just silently
        // stringified into `InternalPanic`/`RuntimePoisoned`.
        crate::panic_forensics::install_panic_hook();
        config.validate().map_err(RuntimeError::InvalidConfig)?;
        let registry = Arc::new(OperationRegistry::new(
            identity.clone(),
            config.cancel_tombstone_window,
        ));
        let subscriptions = Arc::new(SubscriptionHub::new(identity.clone())?);
        let shared = Arc::new(Shared {
            identity,
            registry,
            subscriptions,
            lifecycle: Mutex::new(LifecycleState::Starting),
            lifecycle_changed: Condvar::new(),
            active_tasks: AtomicUsize::new(0),
            task_cancellations: Mutex::new(HashMap::new()),
            shutdown_grace: config.shutdown_grace,
        });
        let (shutdown, shutdown_receiver) = watch::channel(false);
        let (bootstrap_sender, bootstrap_receiver) = std::sync::mpsc::sync_channel(1);
        let thread_shared = Arc::clone(&shared);
        let runtime_thread = thread::Builder::new()
            .name("agentry-runtime".to_owned())
            .spawn(move || runtime_main(thread_shared, shutdown_receiver, bootstrap_sender))
            .map_err(|error| RuntimeError::Startup(error.to_string()))?;
        let handle = bootstrap_receiver
            .recv()
            .map_err(|error| RuntimeError::Startup(error.to_string()))?
            .map_err(RuntimeError::Startup)?;
        Ok(Self {
            shared,
            handle,
            shutdown,
            data_slots: Arc::new(Semaphore::new(config.data_lane_capacity)),
            thread: Mutex::new(Some(runtime_thread)),
        })
    }

    pub fn identity(&self) -> &RuntimeIdentity {
        &self.shared.identity
    }
    pub fn registry(&self) -> &Arc<OperationRegistry> {
        &self.shared.registry
    }
    pub fn subscriptions(&self) -> &Arc<SubscriptionHub> {
        &self.shared.subscriptions
    }
    pub fn lifecycle(&self) -> LifecycleState {
        self.shared.lifecycle()
    }
    pub fn active_task_count(&self) -> usize {
        self.shared.active_tasks.load(Ordering::Acquire)
    }

    pub fn submit<F>(
        &self,
        request: AdmissionRequest,
        operation: F,
    ) -> Result<AdmissionOutcome, RuntimeError>
    where
        F: Future<Output = TerminalOutcome> + Send + 'static,
    {
        let lifecycle = self
            .shared
            .lifecycle
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if *lifecycle != LifecycleState::Running {
            return Err(RuntimeError::ShuttingDown);
        }
        let permit = Arc::clone(&self.data_slots)
            .try_acquire_owned()
            .map_err(|_| RuntimeError::DataLaneSaturated)?;
        let operation_id = request.operation_id.clone();
        let outcome = self.shared.registry.admit(request)?;
        if !matches!(outcome, AdmissionOutcome::Accepted) {
            return Ok(outcome);
        }

        let (cancel_sender, mut cancel_receiver) = watch::channel(false);
        self.shared
            .task_cancellations
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(operation_id.clone(), cancel_sender.clone());
        if self
            .shared
            .registry
            .snapshot(&operation_id)
            .is_some_and(|snapshot| snapshot.state == OperationState::CancelRequested)
        {
            let _ = cancel_sender.send(true);
        }
        let mut shutdown_receiver = self.shutdown.subscribe();
        let task_shared = Arc::clone(&self.shared);
        task_shared.active_tasks.fetch_add(1, Ordering::AcqRel);
        let identity = task_shared.identity.clone();
        let _ = task_shared.registry.mark_running(&identity, &operation_id);
        self.handle.spawn(async move {
            let _permit = permit;
            let terminal = tokio::select! {
                biased;
                _ = shutdown_receiver.changed() => TerminalOutcome::Cancelled,
                _ = cancel_receiver.changed() => TerminalOutcome::Cancelled,
                outcome = operation => outcome,
            };
            let _ = task_shared
                .registry
                .resolve_terminal(&identity, &operation_id, terminal);
            task_shared
                .task_cancellations
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .remove(&operation_id);
            task_shared.active_tasks.fetch_sub(1, Ordering::AcqRel);
            task_shared.lifecycle_changed.notify_all();
        });
        drop(lifecycle);
        Ok(outcome)
    }

    pub fn cancel(
        &self,
        identity: &RuntimeIdentity,
        operation_id: OperationId,
    ) -> Result<CancelOutcome, RuntimeError> {
        let outcome = self
            .shared
            .registry
            .cancel(identity, operation_id.clone())?;
        if let Some(sender) = self
            .shared
            .task_cancellations
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(&operation_id)
        {
            let _ = sender.send(true);
        }
        Ok(outcome)
    }

    pub fn begin_shutdown(
        &self,
        identity: &RuntimeIdentity,
    ) -> Result<ShutdownReceipt, RuntimeError> {
        if identity != &self.shared.identity {
            return Err(RuntimeError::Registry(RegistryError::StaleRuntimeIdentity));
        }
        let mut lifecycle = self
            .shared
            .lifecycle
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if matches!(
            *lifecycle,
            LifecycleState::ShuttingDown | LifecycleState::Stopped
        ) {
            return Ok(ShutdownReceipt {
                already_started: true,
                cancelled_operations: 0,
            });
        }
        *lifecycle = LifecycleState::ShuttingDown;
        self.shared.lifecycle_changed.notify_all();
        drop(lifecycle);
        let cancelled_operations = self.shared.registry.begin_shutdown();
        let _ = self.shared.subscriptions.shutdown(identity);
        let _ = self.shutdown.send(true);
        Ok(ShutdownReceipt {
            already_started: false,
            cancelled_operations,
        })
    }

    pub fn wait_for_terminal(&self, timeout: Duration) -> bool {
        let lifecycle = self
            .shared
            .lifecycle
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if *lifecycle == LifecycleState::Stopped {
            return true;
        }
        let (lifecycle, _) = self
            .shared
            .lifecycle_changed
            .wait_timeout_while(lifecycle, timeout, |state| {
                *state != LifecycleState::Stopped
            })
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        *lifecycle == LifecycleState::Stopped
    }

    pub fn join(&self) {
        if let Some(thread) = self
            .thread
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take()
        {
            let _ = thread.join();
        }
    }
}

impl Drop for CoreRuntime {
    fn drop(&mut self) {
        let identity = self.shared.identity.clone();
        let _ = self.begin_shutdown(&identity);
        let _ = self.wait_for_terminal(
            self.shared
                .shutdown_grace
                .saturating_add(Duration::from_secs(1)),
        );
        self.join();
    }
}

fn runtime_main(
    shared: Arc<Shared>,
    mut shutdown: watch::Receiver<bool>,
    bootstrap: std::sync::mpsc::SyncSender<Result<Handle, String>>,
) {
    let runtime = match Builder::new_current_thread().enable_time().build() {
        Ok(runtime) => runtime,
        Err(error) => {
            let _ = bootstrap.send(Err(error.to_string()));
            shared.set_lifecycle(LifecycleState::Stopped);
            return;
        }
    };
    let handle = runtime.handle().clone();
    shared.set_lifecycle(LifecycleState::Running);
    if bootstrap.send(Ok(handle)).is_err() {
        shared.set_lifecycle(LifecycleState::Stopped);
        return;
    }
    runtime.block_on(async {
        while !*shutdown.borrow() {
            if shutdown.changed().await.is_err() {
                break;
            }
        }
        let deadline = Instant::now() + shared.shutdown_grace;
        while shared.active_tasks.load(Ordering::Acquire) != 0 && Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    });
    drop(runtime);
    shared
        .task_cancellations
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clear();
    shared.active_tasks.store(0, Ordering::Release);
    shared.set_lifecycle(LifecycleState::Stopped);
}
