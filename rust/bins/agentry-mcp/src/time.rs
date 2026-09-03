//! Tiny RFC 3339 UTC clock. The workspace has no `time` / `chrono` crate.

use std::time::{SystemTime, UNIX_EPOCH};

#[must_use]
pub fn rfc3339_now() -> String {
    rfc3339_from_secs(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_secs())
            .unwrap_or(0),
    )
}

#[must_use]
pub fn rfc3339_from_secs(secs: u64) -> String {
    let (year, month, day, hour, minute, second) = civil_utc(secs);
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
}

/// Howard Hinnant's civil-from-days; unix day 0 is 1970-01-01.
fn civil_utc(secs: u64) -> (i32, u32, u32, u32, u32, u32) {
    let z = i64::try_from(secs / 86_400).unwrap_or(0) + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = u64::try_from(z - era * 146_097).unwrap_or(0);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let year = i32::try_from(i64::try_from(yoe).unwrap_or(0) + era * 400).unwrap_or(1970);
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = u32::try_from(doy - (153 * mp + 2) / 5 + 1).unwrap_or(1);
    let month = u32::try_from(if mp < 10 { mp + 3 } else { mp - 9 }).unwrap_or(1);
    let year = if month <= 2 { year + 1 } else { year };
    let rem = secs % 86_400;
    (
        year,
        month,
        day,
        u32::try_from(rem / 3600).unwrap_or(0),
        u32::try_from((rem % 3600) / 60).unwrap_or(0),
        u32::try_from(rem % 60).unwrap_or(0),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unix_epoch_is_rfc3339() {
        assert_eq!(rfc3339_from_secs(0), "1970-01-01T00:00:00Z");
        assert_eq!(rfc3339_from_secs(86_400), "1970-01-02T00:00:00Z");
    }
}
