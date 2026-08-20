use std::time::Duration;

#[derive(Clone, Debug)]
pub struct RuntimeConfig {
    pub data_lane_capacity: usize,
    pub cancel_tombstone_window: Duration,
    pub shutdown_grace: Duration,
}

impl Default for RuntimeConfig {
    fn default() -> Self {
        Self {
            data_lane_capacity: 1_024,
            cancel_tombstone_window: Duration::from_secs(30),
            shutdown_grace: Duration::from_secs(5),
        }
    }
}

impl RuntimeConfig {
    pub(crate) fn validate(&self) -> Result<(), &'static str> {
        if self.data_lane_capacity == 0 {
            return Err("data_lane_capacity must be positive");
        }
        if self.cancel_tombstone_window.is_zero() {
            return Err("cancel_tombstone_window must be positive");
        }
        if self.shutdown_grace.is_zero() {
            return Err("shutdown_grace must be positive");
        }
        Ok(())
    }
}
