// Only fixed labels leave the transport boundary. Never return raw transport
// descriptions here: they can contain addresses, pairing material or identifiers.
pub(crate) fn diagnostic(stage: &str, evidence: &str) -> String {
    let e = evidence.to_ascii_lowercase();
    let kind = if e.contains("pairverify") || e.contains("invalid pairing")
        || e.contains("pairing file is invalid") || e.contains("rejected pairing") {
        "pairing_rejected"
    } else if e.contains("permission denied") || e.contains("operation not permitted") {
        "permission"
    } else if e.contains("timed out") || e.contains("timeout") {
        "timeout"
    } else if e.contains("no route") || e.contains("network is unreachable")
        || e.contains("rsdunreachable") {
        "route_unreachable"
    } else if e.contains("heartbeat") {
        "heartbeat"
    } else { "transport" };
    // An OS code is present only if the underlying Rust io::Error supplied it.
    let code = e.split("code: ").nth(1)
        .and_then(|tail| tail.split(|c: char| !c.is_ascii_digit()).next())
        .filter(|s| !s.is_empty() && s.len() <= 5)
        .and_then(|s| s.parse::<u16>().ok());
    let domain = if code.is_some() { "POSIX" } else { "transport" };
    let stage = match stage { "pairing" => "pairing", _ => "connect" };
    let endpoint = if e.contains("10.7.0.1:49152") { "10.7.0.1:49152" }
        else if e.contains("172.16.0.1:49152") { "172.16.0.1:49152" }
        else if e.contains("10.7.0.1:62078") { "10.7.0.1:62078" }
        else if e.contains("172.16.0.1:62078") { "172.16.0.1:62078" }
        else { "unreported" };
    format!("MIRSA_CONNECTION|{stage}|{kind}|{domain}|{}|{endpoint}", code.map(|c| c.to_string()).unwrap_or_else(|| "unknown".into()))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn pairing() { assert_eq!(diagnostic("pairing","Pairing file is invalid: secret"), "MIRSA_CONNECTION|pairing|pairing_rejected|transport|unknown|unreported"); }
    #[test] fn denied() { assert_eq!(diagnostic("connect","Os { code: 1, kind: PermissionDenied, message: operation not permitted }"), "MIRSA_CONNECTION|connect|permission|POSIX|1|unreported"); }
    #[test] fn route() { assert!(diagnostic("connect","TunnelFailureRsdUnreachable").contains("|route_unreachable|")); }
    #[test] fn timeout() { assert!(diagnostic("connect","RemoteXPC timed out after 2.5s").contains("|timeout|")); }
    #[test] fn heartbeat_not_assumed_pairing() { assert!(diagnostic("connect","heartbeat failed").contains("|heartbeat|")); }
    #[test] fn no_invented_code() { assert!(diagnostic("connect","failed").contains("|transport|unknown|")); }
    #[test] fn strips_private_data() { let d=diagnostic("secret stage", "UDID=private token=secret https://user:pw@host 10.7.0.1 code: 54, heartbeat"); assert_eq!(d,"MIRSA_CONNECTION|connect|heartbeat|POSIX|54|unreported"); }
    #[test] fn reports_only_known_endpoint() {
        assert!(diagnostic("connect", "172.16.0.1:49152: RemoteXPC timed out after 6s").ends_with("|172.16.0.1:49152"));
        assert!(diagnostic("connect", "secret.host:49152 timed out").ends_with("|unreported"));
    }
    #[test] fn pair_verify_evidence() { assert!(diagnostic("connect","TunnelFailurePairVerify").contains("|pairing_rejected|")); }
}
