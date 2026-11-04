//! On-device sideloader for AirCard ("Apps" tab).
//!
//! Built on two MIT-licensed crates:
//!   * isideload (github.com/nab138/isideload): Apple ID login (GSA/SRP + 2FA),
//!     anisette, free development certificate / App ID / provisioning profile
//!     management, and bundle signing (via apple-codesign-quick, LGPL-2.1+).
//!   * idevice (github.com/jkcoxson/idevice): AFC + installation_proxy over the
//!     loopback RSD/Lockdown tunnel that AirCard already opens for its other
//!     features (see `exploit::connect_tunnel`).
//!
//! No code from SideStore, AltStore, SideInstaller or LiveContainer is used.
//!
//! Secrets never live on disk here: every value isideload wants to persist
//! (anisette state, the certificate private key, ...) goes through a key/value
//! store implemented by the Swift side on top of the iOS Keychain.

use std::ffi::{c_char, c_void, CStr, CString};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

use isideload::anisette::remote_v3::RemoteV3AnisetteProvider;
use isideload::auth::apple_account::{
    AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse,
};
use isideload::dev::app_ids::AppIdsApi;
use isideload::dev::certificates::DevelopmentCertificate;
use isideload::dev::developer_session::DeveloperSession;
use isideload::dev::devices::DevicesApi;
use isideload::dev::teams::{DeveloperTeam, TeamsApi};
use isideload::sideload::builder::{ExtensionsBehavior, ExtensionsBehaviorSelection, MaxCertsBehavior};
use isideload::sideload::cert_identity::CertificateIdentity;
use isideload::sideload::sideloader::Sideloader;
use isideload::sideload::{SideloaderBuilder, TeamSelection};
use isideload::util::callbacks::{
    ExtensionsBehaviorCallbackBox, MaxCertsCallbackBox, MaxCertsCallbackFuture,
};
use isideload::util::storage::SideloadingStorage;
use rootcause::prelude::*;
use tokio::sync::Mutex as AsyncMutex;

use crate::exploit::{self, AppDeviceTunnel, Logger};
use crate::ffi_util::{cstr, opt_str};

const MACHINE_NAME: &str = "AirCard";

// ---------------------------------------------------------------------------
// FFI types

/// Key/value store implemented by Swift on top of the Keychain.
/// `get` returns a malloc'd C string (freed here with `free`) or NULL.
/// `set` with an empty value deletes the key.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct ALKeyValueStore {
    pub ctx: *mut c_void,
    pub get: Option<extern "C" fn(ctx: *mut c_void, key: *const c_char) -> *mut c_char>,
    pub set: Option<extern "C" fn(ctx: *mut c_void, key: *const c_char, value: *const c_char)>,
}
unsafe impl Send for ALKeyValueStore {}
unsafe impl Sync for ALKeyValueStore {}

/// Blocking prompt into Swift. Receives a JSON description of what is needed
/// and returns a malloc'd answer string (freed here), or NULL to abort.
///   2FA answers:      "code:123456" | "sms:<id>" | "devices" | "resend" | "abort"
///   max-certs answer: comma separated certificate serials to revoke, or "" to abort
pub type ALPromptCb = Option<extern "C" fn(ctx: *mut c_void, json: *const c_char) -> *mut c_char>;

/// Progress callback: fraction 0...1 and a short stage label.
pub type ALProgressCb = Option<extern "C" fn(ctx: *mut c_void, fraction: f64, stage: *const c_char)>;

#[derive(Clone, Copy)]
struct SendPtr(usize);
unsafe impl Send for SendPtr {}
unsafe impl Sync for SendPtr {}

// ---------------------------------------------------------------------------
// Keychain-backed storage

#[derive(Clone, Copy)]
struct SwiftStorage(ALKeyValueStore);

impl SideloadingStorage for SwiftStorage {
    fn store(&self, key: &str, value: &str) -> Result<(), Report> {
        let set = self.0.set.ok_or_else(|| report!("storage not configured"))?;
        let k = CString::new(key).map_err(|e| report!("bad key: {e}"))?;
        let v = CString::new(value).map_err(|e| report!("bad value: {e}"))?;
        set(self.0.ctx, k.as_ptr(), v.as_ptr());
        Ok(())
    }

    fn retrieve(&self, key: &str) -> Result<Option<String>, Report> {
        let get = self.0.get.ok_or_else(|| report!("storage not configured"))?;
        let k = CString::new(key).map_err(|e| report!("bad key: {e}"))?;
        let p = get(self.0.ctx, k.as_ptr());
        if p.is_null() {
            return Ok(None);
        }
        let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
        unsafe { libc::free(p as *mut c_void) };
        Ok(if s.is_empty() { None } else { Some(s) })
    }

    fn delete(&self, key: &str) -> Result<(), Report> {
        self.store(key, "")
    }
}

static STORAGE: OnceLock<std::sync::Mutex<Option<SwiftStorage>>> = OnceLock::new();

fn storage() -> Result<SwiftStorage, String> {
    STORAGE
        .get_or_init(|| std::sync::Mutex::new(None))
        .lock()
        .map_err(|_| "storage lock poisoned".to_string())?
        .ok_or_else(|| "Keychain storage was not configured (al_sl_set_storage)".to_string())
}

// ---------------------------------------------------------------------------
// Session

struct Session {
    email: String,
    team: DeveloperTeam,
    sideloader: Sideloader<MaxCertsCallbackBox, ExtensionsBehaviorCallbackBox>,
    identity: Option<Arc<CertificateIdentity>>,
    prompt: SendPtr,
    prompt_ctx: SendPtr,
}

static SESSION: OnceLock<AsyncMutex<Option<Session>>> = OnceLock::new();
fn session_lock() -> &'static AsyncMutex<Option<Session>> {
    SESSION.get_or_init(|| AsyncMutex::new(None))
}

static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
fn runtime() -> &'static tokio::runtime::Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_stack_size(4 * 1024 * 1024)
            .thread_name("aircard-sideload")
            .build()
            .expect("tokio runtime")
    })
}

fn init_crypto() {
    static ONCE: OnceLock<()> = OnceLock::new();
    ONCE.get_or_init(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let _ = isideload::init();
    });
}

/// Call a Swift prompt on a blocking thread and return its answer.
async fn ask(prompt: SendPtr, ctx: SendPtr, json: String) -> Option<String> {
    tokio::task::spawn_blocking(move || {
        let cb: extern "C" fn(*mut c_void, *const c_char) -> *mut c_char =
            unsafe { std::mem::transmute(prompt.0) };
        let c = CString::new(json).ok()?;
        let p = cb(ctx.0 as *mut c_void, c.as_ptr());
        if p.is_null() {
            return None;
        }
        let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
        unsafe { libc::free(p as *mut c_void) };
        Some(s)
    })
    .await
    .ok()
    .flatten()
}

fn max_certs_box(prompt: SendPtr, ctx: SendPtr) -> MaxCertsCallbackBox {
    Box::new(move |certs: Vec<DevelopmentCertificate>| -> MaxCertsCallbackFuture {
        Box::pin(async move {
            let list: Vec<serde_json::Value> = certs
                .iter()
                .map(|c| {
                    serde_json::json!({
                        "name": c.name.clone().unwrap_or_default(),
                        "machine_name": c.machine_name.clone().unwrap_or_default(),
                        "serial": c.serial_number.clone().unwrap_or_default(),
                    })
                })
                .collect();
            let json = serde_json::json!({ "kind": "max_certs", "certs": list }).to_string();
            match ask(prompt, ctx, json).await {
                Some(a) if !a.trim().is_empty() => Ok(Some(
                    a.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect(),
                )),
                _ => Ok(None),
            }
        })
    })
}

fn build_sideloader(
    dev_session: DeveloperSession,
    email: &str,
    store: SwiftStorage,
    prompt: SendPtr,
    ctx: SendPtr,
) -> Sideloader<MaxCertsCallbackBox, ExtensionsBehaviorCallbackBox> {
    SideloaderBuilder::<MaxCertsCallbackBox, ExtensionsBehaviorCallbackBox>::new(
        dev_session,
        email.to_string(),
    )
    .team_selection(TeamSelection::First)
    .max_certs_behavior(MaxCertsBehavior::Prompt(max_certs_box(prompt, ctx)))
    .extensions_behavior(ExtensionsBehaviorSelection::Fixed(ExtensionsBehavior::ReuseMain))
    .storage(Box::new(store))
    .machine_name(MACHINE_NAME.to_string())
    .delete_app_after_install(true)
    .build()
}

fn err_string(e: impl std::fmt::Display) -> String {
    format!("{e}")
}

async fn login(
    email: String,
    password: String,
    anisette_url: Option<String>,
    prompt: SendPtr,
    ctx: SendPtr,
) -> Result<serde_json::Value, String> {
    init_crypto();
    let store = storage()?;

    let mut provider = RemoteV3AnisetteProvider::default()
        .map_err(err_string)?
        .set_storage(Box::new(store))
        .set_serial_number("0".to_string());
    if let Some(url) = anisette_url.filter(|u| !u.is_empty()) {
        provider = provider.set_url(&url);
    }

    let two_fa = move |params: TwoFactorCallbackParams| async move {
        let mut v = serde_json::to_value(&params).unwrap_or_default();
        if let Some(obj) = v.as_object_mut() {
            obj.insert("kind".into(), "two_factor".into());
        }
        let answer = ask(prompt, ctx, v.to_string()).await.unwrap_or_default();
        let a = answer.trim();
        Ok(if let Some(code) = a.strip_prefix("code:") {
            TwoFactorCallbackResponse::SubmitCode(code.trim().to_string())
        } else if let Some(id) = a.strip_prefix("sms:") {
            TwoFactorCallbackResponse::SendSms(id.trim().parse().unwrap_or(0))
        } else if a == "devices" {
            TwoFactorCallbackResponse::SendToDevices
        } else if a == "resend" {
            TwoFactorCallbackResponse::ResendCode
        } else {
            TwoFactorCallbackResponse::Abort
        })
    };

    let mut account = AppleAccount::builder(&email)
        .anisette_provider(provider)
        .login(&password, two_fa)
        .await
        .map_err(|e| format!("Apple ID sign-in failed: {e}"))?;

    let (first, last) = account.get_name().unwrap_or_default();
    let mut dev_session = DeveloperSession::from_account(&mut account)
        .await
        .map_err(|e| format!("Developer session failed: {e}"))?;

    let teams = dev_session
        .list_teams()
        .await
        .map_err(|e| format!("Could not list developer teams: {e}"))?;
    let team = teams
        .into_iter()
        .next()
        .ok_or_else(|| "This Apple ID has no developer team".to_string())?;

    let sideloader = build_sideloader(dev_session, &email, store, prompt, ctx);
    let info = serde_json::json!({
        "email": email,
        "name": format!("{first} {last}").trim().to_string(),
        "team_id": team.team_id,
        "team_name": team.name.clone().unwrap_or_default(),
        "team_type": team.r#type.clone().unwrap_or_default(),
    });

    *session_lock().lock().await = Some(Session {
        email,
        team,
        sideloader,
        identity: None,
        prompt,
        prompt_ctx: ctx,
    });
    Ok(info)
}

async fn identity(s: &mut Session) -> Result<Arc<CertificateIdentity>, String> {
    if let Some(id) = &s.identity {
        return Ok(id.clone());
    }
    let store = storage()?;
    let behavior: MaxCertsBehavior<MaxCertsCallbackBox> =
        MaxCertsBehavior::Prompt(max_certs_box(s.prompt, s.prompt_ctx));
    let id = CertificateIdentity::retrieve(
        MACHINE_NAME,
        &s.email,
        s.sideloader.get_dev_session(),
        &s.team,
        &store,
        &behavior,
    )
    .await
    .map_err(|e| format!("Could not get the development certificate: {e}"))?;
    let id = Arc::new(id);
    s.identity = Some(id.clone());
    Ok(id)
}

fn time_to_unix(t: &x509_cert::time::Time) -> u64 {
    t.to_unix_duration().as_secs()
}

async fn account_info() -> Result<serde_json::Value, String> {
    let mut guard = session_lock().lock().await;
    let s = guard.as_mut().ok_or_else(|| "Not signed in".to_string())?;
    let id = identity(s).await?;
    let team = s.team.clone();
    let ids = s
        .sideloader
        .get_dev_session()
        .list_app_ids(&team, None)
        .await
        .map_err(|e| format!("Could not list App IDs: {e}"))?;
    let app_ids: Vec<serde_json::Value> = ids
        .app_ids
        .iter()
        .map(|a| {
            serde_json::json!({
                "identifier": a.identifier,
                "name": a.name,
                "expires": a.expiration_date.map(|d| {
                    std::time::SystemTime::from(d)
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|x| x.as_secs())
                        .unwrap_or(0)
                }),
            })
        })
        .collect();
    Ok(serde_json::json!({
        "email": s.email,
        "team_id": team.team_id,
        "team_name": team.name.clone().unwrap_or_default(),
        "cert_serial": id.get_serial_number(),
        "cert_expires": time_to_unix(&id.certificate.tbs_certificate.validity.not_after),
        "app_ids_available": ids.available_quantity,
        "app_ids_max": ids.max_quantity,
        "app_ids": app_ids,
    }))
}

fn profile_expiry(bundle_dir: &Path) -> Option<u64> {
    let data = std::fs::read(bundle_dir.join("embedded.mobileprovision")).ok()?;
    let profile = apple_codesign_quick::ProvisioningProfile::parse(&data).ok()?;
    match profile.plist().get("ExpirationDate")? {
        plist::Value::Date(d) => std::time::SystemTime::from(*d)
            .duration_since(std::time::UNIX_EPOCH)
            .ok()
            .map(|d| d.as_secs()),
        _ => None,
    }
}

fn read_info(bundle_dir: &Path) -> plist::Dictionary {
    plist::Value::from_file(bundle_dir.join("Info.plist"))
        .ok()
        .and_then(|v| v.into_dictionary())
        .unwrap_or_default()
}

async fn install(
    pairing_path: String,
    app_path: String,
    device_name: String,
    logger: &Logger,
    progress: impl Fn(f64, &str) + Send + Sync + Clone + 'static,
) -> Result<serde_json::Value, String> {
    let pairing = std::fs::read(&pairing_path).map_err(|e| format!("Read pairing file: {e}"))?;
    progress(0.02, "Connecting to device");
    let tunnel = exploit::connect_tunnel(&pairing, logger).await?;

    // Work out the device UDID (needed to register it with the team).
    let (udid, name) = match &tunnel {
        AppDeviceTunnel::Rsd { handshake, .. } => {
            let udid = handshake
                .properties
                .get("UniqueDeviceID")
                .and_then(|v| v.as_string())
                .map(|s| s.to_string())
                .ok_or_else(|| "Device did not report its UDID over RSD".to_string())?;
            let name = handshake
                .properties
                .get("DeviceName")
                .and_then(|v| v.as_string())
                .map(|s| s.to_string())
                .unwrap_or(device_name.clone());
            (udid, name)
        }
        AppDeviceTunnel::Lockdown { provider, .. } => {
            let info = isideload::util::device::IdeviceInfo::from_device(provider)
                .await
                .map_err(|e| format!("Could not read device info: {e}"))?;
            (info.udid, info.name)
        }
    };

    let mut guard = session_lock().lock().await;
    let s = guard.as_mut().ok_or_else(|| "Not signed in".to_string())?;
    let team = s.team.clone();
    progress(0.08, "Registering device");
    s.sideloader
        .get_dev_session()
        .ensure_device_registered(&team, &name, &udid, None)
        .await
        .map_err(|e| format!("Could not register this iPhone with your team: {e}"))?;

    progress(0.12, "Signing");
    let p2 = progress.clone();
    let (signed, _special) = s
        .sideloader
        .sign_app(
            PathBuf::from(&app_path),
            Some(team.clone()),
            false,
            Some(move |f: f32| {
                let p3 = p2.clone();
                async move { p3(0.12 + f as f64 * 0.38, "Signing") }
            }),
            None,
            Some(&udid),
        )
        .await
        .map_err(|e| format!("Signing failed: {e}"))?;
    drop(guard);

    let info = read_info(&signed);
    let bundle_id = info.get("CFBundleIdentifier").and_then(|v| v.as_string()).unwrap_or_default().to_string();
    let expires = profile_expiry(&signed);

    progress(0.5, "Installing");
    let p4 = progress.clone();
    let cb = move |pct: u64| p4(0.5 + (pct as f64 / 100.0) * 0.5, "Installing");
    let res = match tunnel {
        AppDeviceTunnel::Rsd { mut adapter, mut handshake } => {
            isideload::sideload::install::install_app_rsd(&mut adapter, &mut handshake, &signed, cb).await
        }
        AppDeviceTunnel::Lockdown { provider, .. } => {
            isideload::sideload::install::install_app(&provider, &signed, cb).await
        }
    };
    // Clean the temp extraction folder isideload created for an .ipa input.
    if let Some(extracted) = signed.ancestors().find(|p| {
        p.file_name().map(|n| n.to_string_lossy().ends_with("_extracted")).unwrap_or(false)
    }) {
        let _ = std::fs::remove_dir_all(extracted);
    }
    res.map_err(|e| format!("Install failed: {e}"))?;
    progress(1.0, "Done");

    Ok(serde_json::json!({
        "bundle_id": bundle_id,
        "name": info.get("CFBundleDisplayName").or_else(|| info.get("CFBundleName")).and_then(|v| v.as_string()).unwrap_or_default(),
        "version": info.get("CFBundleShortVersionString").and_then(|v| v.as_string()).unwrap_or_default(),
        "expires": expires,
        "team_id": team.team_id,
    }))
}

async fn uninstall(pairing_path: String, bundle_id: String, logger: &Logger) -> Result<(), String> {
    use idevice::services::installation_proxy::InstallationProxyClient;
    use idevice::{IdeviceService, RsdService};
    let pairing = std::fs::read(&pairing_path).map_err(|e| format!("Read pairing file: {e}"))?;
    let tunnel = exploit::connect_tunnel(&pairing, logger).await?;
    let mut client = match tunnel {
        AppDeviceTunnel::Rsd { mut adapter, mut handshake } => {
            InstallationProxyClient::connect_rsd(&mut adapter, &mut handshake)
                .await
                .map_err(|e| format!("installation_proxy: {e:?}"))?
        }
        AppDeviceTunnel::Lockdown { provider, .. } => InstallationProxyClient::connect(&provider)
            .await
            .map_err(|e| format!("installation_proxy: {e:?}"))?,
    };
    client
        .uninstall(bundle_id, None)
        .await
        .map_err(|e| format!("Uninstall failed: {e:?}"))
}

// ---------------------------------------------------------------------------
// Container signing (JIT-less): sign guest Mach-O files with our dev cert

fn signer_for(id: &CertificateIdentity) -> Result<apple_codesign_quick::RustCryptoCmsSigner, String> {
    use x509_cert::der::Decode;
    let chain = [
        isideload::sideload::cert_identity::APPLE_WWDR_G3_CERTIFICATE_DER,
        isideload::sideload::cert_identity::APPLE_ROOT,
    ]
    .iter()
    .map(|d| x509_cert::Certificate::from_der(d).map_err(|e| format!("bad bundled CA cert: {e}")))
    .collect::<Result<Vec<_>, _>>()?;
    Ok(apple_codesign_quick::RustCryptoCmsSigner::new(
        id.private_key.clone(),
        id.certificate.clone(),
        chain,
    ))
}

async fn container_sign(app_dir: String) -> Result<serde_json::Value, String> {
    let (id, team_id) = {
        let mut guard = session_lock().lock().await;
        let s = guard.as_mut().ok_or_else(|| "Sign in with your Apple ID first".to_string())?;
        (identity(s).await?, s.team.team_id.clone())
    };
    let dir = PathBuf::from(&app_dir);
    let serial = id.get_serial_number();
    let team = team_id.clone();
    tokio::task::spawn_blocking(move || -> Result<serde_json::Value, String> {
        let signer = signer_for(&id)?;
        let prepared = crate::container::prepare_bundle(&dir)?;
        let empty = plist::Dictionary::new();
        let mut signed = 0usize;
        for (path, ident) in &prepared.macho_files {
            let cfg = apple_codesign_quick::MachOSigningConfig::new(ident, &team, &empty, Some(&signer));
            apple_codesign_quick::sign_macho_file(path, &cfg)
                .map_err(|e| format!("Signing {} failed: {e}", path.display()))?;
            signed += 1;
        }
        Ok(serde_json::json!({
            "executable": prepared.executable.to_string_lossy(),
            "signed_files": signed,
            "cert_serial": serial,
            "team_id": team,
        }))
    })
    .await
    .map_err(|e| format!("signing task failed: {e}"))?
}

// ---------------------------------------------------------------------------
// FFI surface

fn write_result(
    res: Result<serde_json::Value, String>,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    unsafe {
        match res {
            Ok(v) => {
                if !out_json.is_null() {
                    *out_json = cstr(v.to_string());
                }
                0
            }
            Err(e) => {
                if !out_error.is_null() {
                    *out_error = cstr(e);
                }
                1
            }
        }
    }
}

fn guarded<F: FnOnce() -> Result<serde_json::Value, String> + std::panic::UnwindSafe>(
    name: &str,
    f: F,
) -> Result<serde_json::Value, String> {
    match std::panic::catch_unwind(f) {
        Ok(r) => r,
        Err(e) => Err(format!("Rust panic in {name}: {e:?}")),
    }
}

/// Configure the Keychain-backed store. Call once at launch.
#[no_mangle]
pub extern "C" fn al_sl_set_storage(store: ALKeyValueStore) -> i32 {
    if let Ok(mut g) = STORAGE.get_or_init(|| std::sync::Mutex::new(None)).lock() {
        *g = Some(SwiftStorage(store));
        0
    } else {
        1
    }
}

/// Sign in with an Apple ID. BLOCKS (network + 2FA prompt) — call off the main thread.
#[no_mangle]
pub unsafe extern "C" fn al_sl_login(
    email: *const c_char,
    password: *const c_char,
    anisette_url: *const c_char,
    prompt_cb: ALPromptCb,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let email = opt_str(email, "");
    let password = opt_str(password, "");
    let url = opt_str(anisette_url, "");
    let Some(cb) = prompt_cb else {
        return write_result(Err("prompt callback required".into()), out_json, out_error);
    };
    let prompt = SendPtr(cb as usize);
    let c = SendPtr(ctx as usize);
    let res = guarded("al_sl_login", move || {
        runtime().block_on(login(email, password, Some(url), prompt, c))
    });
    write_result(res, out_json, out_error)
}

/// 1 when a session is active.
#[no_mangle]
pub extern "C" fn al_sl_is_logged_in() -> i32 {
    runtime().block_on(async { session_lock().lock().await.is_some() as i32 })
}

/// Drop the in-memory session (Keychain values are cleared by Swift).
#[no_mangle]
pub extern "C" fn al_sl_logout() {
    runtime().block_on(async { *session_lock().lock().await = None });
}

/// Team, certificate and App ID quota as JSON. BLOCKS.
#[no_mangle]
pub unsafe extern "C" fn al_sl_account_info(out_json: *mut *mut c_char, out_error: *mut *mut c_char) -> i32 {
    let res = guarded("al_sl_account_info", || runtime().block_on(account_info()));
    write_result(res, out_json, out_error)
}

/// Sign `app_path` (.ipa or .app) with the free dev cert and install it as a
/// real app over the loopback tunnel. BLOCKS.
#[no_mangle]
pub unsafe extern "C" fn al_sl_install(
    pairing_path: *const c_char,
    app_path: *const c_char,
    device_name: *const c_char,
    progress_cb: ALProgressCb,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing = opt_str(pairing_path, "");
    let app = opt_str(app_path, "");
    let dev = opt_str(device_name, "iPhone");
    let c = SendPtr(ctx as usize);
    let pcb = progress_cb.map(|f| SendPtr(f as usize));
    let res = guarded("al_sl_install", move || {
        let logger = Logger { cb: log_cb, ctx: c.0 as *mut c_void };
        let progress = move |f: f64, stage: &str| {
            if let Some(p) = pcb {
                let cb: extern "C" fn(*mut c_void, f64, *const c_char) = unsafe { std::mem::transmute(p.0) };
                if let Ok(s) = CString::new(stage) {
                    cb(c.0 as *mut c_void, f, s.as_ptr());
                }
            }
        };
        runtime().block_on(install(pairing, app, dev, &logger, progress))
    });
    write_result(res, out_json, out_error)
}

/// Uninstall a real app by bundle id over the tunnel. BLOCKS.
#[no_mangle]
pub unsafe extern "C" fn al_sl_uninstall(
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing = opt_str(pairing_path, "");
    let bid = opt_str(bundle_id, "");
    let c = SendPtr(ctx as usize);
    let res = guarded("al_sl_uninstall", move || {
        let logger = Logger { cb: log_cb, ctx: c.0 as *mut c_void };
        runtime()
            .block_on(uninstall(pairing, bid, &logger))
            .map(|_| serde_json::Value::Null)
    });
    write_result(res, std::ptr::null_mut(), out_error)
}

/// Prepare an extracted guest .app for the container (Mach-O -> dylib patch)
/// and sign every Mach-O in it with the session's dev certificate. BLOCKS.
#[no_mangle]
pub unsafe extern "C" fn al_container_sign(
    app_dir: *const c_char,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let dir = opt_str(app_dir, "");
    let res = guarded("al_container_sign", move || runtime().block_on(container_sign(dir)));
    write_result(res, out_json, out_error)
}
