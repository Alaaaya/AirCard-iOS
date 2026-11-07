use std::net::Ipv4Addr;
use std::time::Duration;
pub(crate) const ATTEMPT_LIMIT: Duration = Duration::from_secs(6);
pub(crate) const TOTAL_LIMIT: Duration = Duration::from_secs(20);

pub(crate) fn device_host(host: &str) -> Option<String> {
    let ip = host.trim().parse::<Ipv4Addr>().ok()?;
    // LocalDevVPN's tunnel interface is not the device endpoint.
    if ip.is_loopback() || ip.is_unspecified() || ip.is_multicast()
        || ip == Ipv4Addr::BROADCAST || ip == Ipv4Addr::new(10,7,1,1) { return None; }
    Some(ip.to_string())
}
pub(crate) fn candidates(preferred: Option<&str>) -> Vec<String> {
    let mut hosts = Vec::new();
    for h in preferred.into_iter().chain(["10.7.0.1", "172.16.0.1"]) {
        if let Some(h) = device_host(h) {
            if !hosts.contains(&h) { hosts.push(h); }
        }
    }
    hosts
}

// Shared outer budget. Cancellation drops the inner future and its sockets.
pub(crate) async fn bounded<F: std::future::Future>(limit: Duration, work: F)
    -> Result<F::Output, tokio::time::error::Elapsed> {
    tokio::time::timeout(limit, work).await
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test] async fn overall_budget_cancels_pending_work() {
        use std::sync::{Arc, atomic::{AtomicBool, Ordering}};
        struct Dropped(Arc<AtomicBool>);
        impl Drop for Dropped { fn drop(&mut self) { self.0.store(true, Ordering::SeqCst); } }
        let cancelled = Arc::new(AtomicBool::new(false));
        let marker = Dropped(cancelled.clone());
        let result = bounded(Duration::from_millis(10), async move {
            let _marker = marker;
            std::future::pending::<()>().await;
        }).await;
        assert!(result.is_err());
        assert!(cancelled.load(Ordering::SeqCst));
    }
    #[tokio::test] async fn shared_budget_allows_success() {
        assert_eq!(bounded(TOTAL_LIMIT, async { 42 }).await.unwrap(), 42);
        assert!(ATTEMPT_LIMIT < TOTAL_LIMIT);
    }
    #[test] fn defaults_and_preference() {
        assert_eq!(candidates(None), vec!["10.7.0.1","172.16.0.1"]);
        assert_eq!(candidates(Some("172.16.0.1")), vec!["172.16.0.1","10.7.0.1"]);
    }
    #[test] fn tunnel_not_device() {
        assert_eq!(candidates(Some("10.7.1.1")), candidates(None));
    }
    #[test] fn no_url_or_loopback() {
        for h in ["https://host", "127.0.0.1", "0.0.0.0", "224.0.0.1", "1.2.3.999"] {
            assert!(device_host(h).is_none());
        }
    }
}
