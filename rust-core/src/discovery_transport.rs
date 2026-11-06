//! No URL substitution: reqwest connects to vetted DNS overrides while TLS/SNI
//! and Host still use the original URL hostname. Fresh client on EVERY hop.
//! No proxy, cookies, credentials, automatic redirects or connection-pool reuse.
use reqwest::{Client, Url};
use std::{
    ffi::{c_char, CStr},
    net::{IpAddr, SocketAddr},
    path::Path,
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};
type Result<T> = std::result::Result<T, &'static str>;

fn public(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v) => {
            let [a, b, c, _] = v.octets();
            !(a == 0
                || a == 10
                || a == 127
                || a >= 224
                || a == 100 && (64..=127).contains(&b)
                || a == 169 && b == 254
                || a == 172 && (16..=31).contains(&b)
                || a == 192 && (b == 168 || b == 0 || b == 2 || b == 88 && c == 99)
                || a == 198 && (b == 18 || b == 19 || b == 51 && c == 100)
                || a == 203 && b == 0 && c == 113)
        }
        IpAddr::V6(v) => {
            let s = v.segments();
            (0x2000..=0x3fff).contains(&s[0]) && s[0] != 0x2001 && s[0] != 0x2002
        }
    }
}
fn safe_url(url: &Url) -> Result<&str> {
    let host = url.host_str().ok_or("Missing hostname")?;
    if url.scheme() != "https"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port_or_known_default() != Some(443)
        || url.fragment().is_some()
        || host.parse::<IpAddr>().is_ok()
        || !host.contains('.')
        || host.ends_with('.')
        || [
            ".local",
            ".localhost",
            ".internal",
            ".lan",
            ".home",
            ".test",
            ".invalid",
            ".example",
        ]
        .iter()
        .any(|suffix| host.ends_with(suffix))
    {
        return Err("Unsafe download URL");
    }
    Ok(host)
}
fn checked_addrs(addrs: Vec<SocketAddr>) -> Result<Vec<SocketAddr>> {
    if addrs.is_empty() || addrs.iter().any(|a| !public(a.ip()) || a.port() != 443) {
        return Err("Non-public DNS refused");
    }
    Ok(addrs)
}
fn pinned_builder(host: &str, addrs: &[SocketAddr]) -> reqwest::ClientBuilder {
    Client::builder()
        .tls_backend_rustls()
        .https_only(true)
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .referer(false)
        .resolve_to_addrs(host, addrs)
        .connect_timeout(Duration::from_secs(15))
        .no_gzip()
        .no_brotli()
        .no_deflate()
        .no_zstd()
}
fn pinned_client(host: &str, addrs: &[SocketAddr]) -> Result<Client> {
    pinned_builder(host, addrs)
        .build()
        .map_err(|_| "TLS transport unavailable")
}
fn checked_peer(peer: Option<SocketAddr>, addrs: &[SocketAddr]) -> Result<()> {
    if peer.is_none_or(|p| !public(p.ip()) || !addrs.contains(&p)) {
        return Err("Connection address did not match pinned DNS");
    }
    Ok(())
}
async fn download(
    url: &str,
    dest: &Path,
    max: u64,
    seconds: u64,
    cancel: &AtomicBool,
) -> Result<()> {
    let mut url = Url::parse(url).map_err(|_| "Invalid download URL")?;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(seconds.clamp(1, 1800));
    let work = async {
        for hop in 0..=5 {
            if cancel.load(Ordering::Relaxed) {
                return Err("Cancelled");
            }
            let host = safe_url(&url)?.to_owned();
            let answers = tokio::net::lookup_host((host.as_str(), 443))
                .await
                .map_err(|_| "DNS failed")?
                .collect();
            let addrs = checked_addrs(answers)?;
            let client = pinned_client(&host, &addrs)?;
            let mut response = client
                .get(url.clone())
                .header("Accept-Encoding", "identity")
                .send()
                .await
                .map_err(|_| "HTTPS download failed")?;
            checked_peer(response.remote_addr(), &addrs)?;
            if response.status().is_redirection() {
                if hop == 5 {
                    return Err("Too many redirects");
                }
                let location = response
                    .headers()
                    .get("location")
                    .and_then(|h| h.to_str().ok())
                    .ok_or("Missing redirect")?;
                url = url.join(location).map_err(|_| "Invalid redirect")?;
                safe_url(&url)?; // Never dispatch an unchecked hop.
                continue;
            }
            if response.status().as_u16() != 200 {
                return Err("Download host refused request");
            }
            let content_type = response
                .headers()
                .get("content-type")
                .and_then(|h| h.to_str().ok())
                .unwrap_or("");
            if content_type.to_ascii_lowercase().contains("text/html") {
                return Err("Web page is not an IPA");
            }
            if response
                .headers()
                .get("content-encoding")
                .is_some_and(|h| h != "identity")
            {
                return Err("Encoded download refused");
            }
            if response.content_length().is_some_and(|n| n > max) {
                return Err("Download too large");
            }
            use std::io::Write;
            let mut out = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(dest)
                .map_err(|_| "Cannot create temporary download")?;
            let mut total = 0u64;
            while let Some(bytes) = response.chunk().await.map_err(|_| "Download interrupted")? {
                if cancel.load(Ordering::Relaxed) {
                    return Err("Cancelled");
                }
                total = total
                    .checked_add(bytes.len() as u64)
                    .ok_or("Download too large")?;
                if total > max {
                    return Err("Download too large");
                }
                out.write_all(&bytes).map_err(|_| "Cannot save download")?;
            }
            if cancel.load(Ordering::Relaxed) {
                return Err("Cancelled");
            }
            if total == 0 {
                return Err("Empty download");
            }
            return Ok(());
        }
        Err("Too many redirects")
    };
    tokio::select! {
        result = tokio::time::timeout_at(deadline, work) =>
            result.map_err(|_| "Download timed out")?,
        _ = async {
            loop {
                if cancel.load(Ordering::Relaxed) { break; }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        } => Err("Cancelled"),
    }
}

#[no_mangle]
pub extern "C" fn al_discovery_cancel_new() -> *mut AtomicBool {
    Box::into_raw(Box::new(AtomicBool::new(false)))
}
#[no_mangle]
pub unsafe extern "C" fn al_discovery_cancel(token: *mut AtomicBool) {
    if let Some(t) = token.as_ref() {
        t.store(true, Ordering::Relaxed);
    }
}
#[no_mangle]
pub unsafe extern "C" fn al_discovery_cancel_free(token: *mut AtomicBool) {
    if !token.is_null() {
        drop(Box::from_raw(token));
    }
}
/// Called on a dedicated Swift worker, never a Tokio runtime thread. Error
/// contains no URL, query, token or server-controlled body. Caller owns paths.
#[no_mangle]
pub unsafe extern "C" fn al_discovery_download(
    url: *const c_char,
    dest: *const c_char,
    max: u64,
    seconds: u64,
    cancel: *const AtomicBool,
) -> *mut c_char {
    let result = std::panic::catch_unwind(|| -> Result<()> {
        if url.is_null() || dest.is_null() || cancel.is_null() {
            return Err("Invalid download arguments");
        }
        let url = CStr::from_ptr(url).to_str().map_err(|_| "Invalid URL")?;
        let dest = CStr::from_ptr(dest).to_str().map_err(|_| "Invalid path")?;
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|_| "Download runtime unavailable")?;
        let result = runtime.block_on(download(
            url,
            Path::new(dest),
            max.min(3 * 1024 * 1024 * 1024),
            seconds,
            &*cancel,
        ));
        if result.is_err() {
            let _ = std::fs::remove_file(dest);
        }
        result
    })
    .unwrap_or(Err("Download transport failed"));
    match result {
        Ok(()) => std::ptr::null_mut(),
        Err(e) => crate::ffi_util::cstr(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn public_answers_only() {
        for ip in [
            "127.0.0.1",
            "10.0.0.1",
            "169.254.169.254",
            "100.64.1.1",
            "192.0.2.1",
            "198.18.0.1",
            "::1",
            "::ffff:8.8.8.8",
            "2001:db8::1",
            "2002:808:808::1",
        ] {
            assert!(
                checked_addrs(vec![SocketAddr::new(ip.parse().unwrap(), 443)]).is_err(),
                "{ip}"
            );
        }
        assert!(checked_addrs(vec![]).is_err());
        assert!(checked_addrs(vec![
            "8.8.8.8:443".parse().unwrap(),
            "127.0.0.1:443".parse().unwrap()
        ])
        .is_err());
    }
    #[test]
    fn rebinding_cannot_change_connected_peer() {
        let pinned = checked_addrs(vec!["8.8.8.8:443".parse().unwrap()]).unwrap();
        assert!(checked_peer(Some("127.0.0.1:443".parse().unwrap()), &pinned).is_err());
        assert!(checked_peer(Some("10.0.0.1:443".parse().unwrap()), &pinned).is_err());
        assert!(checked_peer(None, &pinned).is_err());
        assert!(checked_peer(Some(pinned[0]), &pinned).is_ok());
    }
    #[test]
    fn every_redirect_is_revalidated() {
        let base = Url::parse("https://downloads.good.org/app.ipa").unwrap();
        for target in [
            "http://downloads.good.org/app.ipa",
            "https://127.0.0.1/a",
            "https://x.local/a",
            "https://user:pass@evil.org/a",
            "https://evil.org:8443/a",
            "https://evil.org/a#fragment",
        ] {
            assert!(safe_url(&base.join(target).unwrap()).is_err(), "{target}");
        }
        assert_eq!(safe_url(&base).unwrap(), "downloads.good.org");
    }
    #[test]
    fn download_entry_fails_closed_before_creating_file() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let path = std::env::temp_dir().join(format!("mirsa-refused-{}", std::process::id()));
        let cancel = AtomicBool::new(false);
        for url in [
            "https://127.0.0.1/app.ipa",
            "https://169.254.169.254/app.ipa",
            "https://localhost/app.ipa",
            "http://valid.org/app.ipa",
        ] {
            assert!(rt.block_on(download(url, &path, 1024, 1, &cancel)).is_err());
            assert!(
                !path.exists(),
                "refused destinations must not create output"
            );
        }
    }

    // Real socket + real rustls certificate verification, no custom TLS verifier.
    // The local address exception exists ONLY in this test's builder invocation.
    #[test]
    fn socket_pin_keeps_original_tls_hostname_and_never_reresolves() {
        use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
        use std::{
            io::{Read, Write},
            sync::{atomic::AtomicUsize, Arc},
        };
        struct RebindingDNS(Arc<AtomicUsize>);
        impl reqwest::dns::Resolve for RebindingDNS {
            fn resolve(&self, _: reqwest::dns::Name) -> reqwest::dns::Resolving {
                self.0.fetch_add(1, Ordering::SeqCst);
                Box::pin(async {
                    Ok(Box::new(vec!["10.0.0.1:443".parse().unwrap()].into_iter())
                        as reqwest::dns::Addrs)
                })
            }
        }
        let cert = include_bytes!("../tests/fixtures/pinning-cert.der");
        let key = include_bytes!("../tests/fixtures/pinning-key.der");
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let config = rustls::ServerConfig::builder_with_provider(Arc::new(
                rustls::crypto::aws_lc_rs::default_provider(),
            ))
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(
                vec![CertificateDer::from(cert.to_vec())],
                PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.to_vec())),
            )
            .unwrap();
            let mut requests = Vec::new();
            for _ in 0..2 {
                let (socket, _) = listener.accept().unwrap();
                socket
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let conn = rustls::ServerConnection::new(Arc::new(config.clone())).unwrap();
                let mut tls = rustls::StreamOwned::new(conn, socket);
                let mut buf = [0; 4096];
                if let Ok(n) = tls.read(&mut buf) {
                    requests.push(String::from_utf8_lossy(&buf[..n]).into_owned());
                    let _ = tls.write_all(
                        b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK",
                    );
                }
            }
            requests
        });
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        rt.block_on(async {
            for (host, succeeds) in [("mirsa-pinning.test", true), ("wrong-pinning.test", false)] {
                let client = pinned_builder(host, &[addr])
                    .tls_certs_only([reqwest::Certificate::from_der(cert).unwrap()])
                    .dns_resolver(Arc::new(RebindingDNS(calls.clone())))
                    .build()
                    .unwrap();
                let response = client
                    .get(format!("https://{host}:{}/ipa", addr.port()))
                    .send()
                    .await;
                assert_eq!(response.is_ok(), succeeds, "{response:?}");
                if let Ok(r) = response {
                    assert_eq!(r.text().await.unwrap(), "OK");
                }
            }
        });
        assert_eq!(
            calls.load(Ordering::SeqCst),
            0,
            "override must prevent a second DNS query"
        );
        let requests = server.join().unwrap();
        assert_eq!(requests.len(), 1, "wrong TLS hostname must not send HTTP");
        assert!(requests[0]
            .to_lowercase()
            .contains("host: mirsa-pinning.test:"));
        assert!(!requests[0].to_lowercase().contains("authorization:"));
        assert!(!requests[0].to_lowercase().contains("cookie:"));
    }
}
