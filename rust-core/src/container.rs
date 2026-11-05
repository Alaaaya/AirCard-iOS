//! Container preparation: turn a guest app's main executable into a loadable
//! dylib so AirCard can `dlopen` it in its own process.
//!
//! This is an independent implementation written for AirCard of the generally
//! known "load an iOS app as a library" technique. No LiveContainer (AGPL-3.0)
//! source was copied. Steps for the main executable:
//!   1. thin a FAT binary to its arm64 slice
//!   2. refuse FairPlay-encrypted (App Store) binaries
//!   3. MH_EXECUTE -> MH_DYLIB
//!   4. shrink __PAGEZERO to a single page directly below __TEXT so dyld does
//!      not have to reserve 4 GB of address space for the image
//!   5. rewrite `@executable_path` -> `@loader_path` in LC_RPATH / dylib load
//!      commands (inside a dylib, @executable_path would point at AirCard)
//!   6. add an LC_ID_DYLIB command when the header has room for it
//! Embedded frameworks/dylibs are only collected for re-signing.

use std::path::{Path, PathBuf};

const MH_MAGIC_64: u32 = 0xfeed_facf;
const FAT_MAGIC: u32 = 0xcafe_babe;
const FAT_MAGIC_64: u32 = 0xcafe_babf;
const CPU_TYPE_ARM64: u32 = 0x0100_000c;
const MH_DYLIB: u32 = 6;

const LC_SEGMENT_64: u32 = 0x19;
const LC_ID_DYLIB: u32 = 0x0d;
const LC_LOAD_DYLIB: u32 = 0x0c;
const LC_LOAD_WEAK_DYLIB: u32 = 0x8000_0018;
const LC_REEXPORT_DYLIB: u32 = 0x8000_001f;
const LC_LOAD_UPWARD_DYLIB: u32 = 0x8000_0023;
const LC_LAZY_LOAD_DYLIB: u32 = 0x20;
const LC_RPATH: u32 = 0x8000_001c;
const LC_ENCRYPTION_INFO_64: u32 = 0x2c;
const LC_CODE_SIGNATURE: u32 = 0x1d;

pub struct PreparedBundle {
    pub executable: PathBuf,
    /// Every Mach-O to sign, with the code-signing identifier to use.
    pub macho_files: Vec<(PathBuf, String)>,
}

fn rd32(d: &[u8], o: usize) -> u32 {
    u32::from_le_bytes(d[o..o + 4].try_into().unwrap())
}
fn wr32(d: &mut [u8], o: usize, v: u32) {
    d[o..o + 4].copy_from_slice(&v.to_le_bytes());
}
fn rd64(d: &[u8], o: usize) -> u64 {
    u64::from_le_bytes(d[o..o + 8].try_into().unwrap())
}
fn wr64(d: &mut [u8], o: usize, v: u64) {
    d[o..o + 8].copy_from_slice(&v.to_le_bytes());
}
fn rdbe32(d: &[u8], o: usize) -> u32 {
    u32::from_be_bytes(d[o..o + 4].try_into().unwrap())
}

fn is_macho(d: &[u8]) -> bool {
    d.len() >= 32 && {
        let le = rd32(d, 0);
        let be = rdbe32(d, 0);
        le == MH_MAGIC_64 || be == FAT_MAGIC || be == FAT_MAGIC_64
    }
}

/// Return the arm64 slice of a FAT binary, or the input when already thin.
pub fn thin_arm64(d: Vec<u8>) -> Result<Vec<u8>, String> {
    if d.len() < 8 {
        return Err("file too small to be Mach-O".into());
    }
    let magic = rdbe32(&d, 0);
    if magic != FAT_MAGIC && magic != FAT_MAGIC_64 {
        return Ok(d);
    }
    let n = rdbe32(&d, 4) as usize;
    let is64 = magic == FAT_MAGIC_64;
    let entry = if is64 { 32 } else { 20 };
    for i in 0..n {
        let o = 8 + i * entry;
        if o + entry > d.len() {
            break;
        }
        let cpu = rdbe32(&d, o);
        if cpu != CPU_TYPE_ARM64 {
            continue;
        }
        let (off, size) = if is64 {
            (
                u64::from_be_bytes(d[o + 8..o + 16].try_into().unwrap()) as usize,
                u64::from_be_bytes(d[o + 16..o + 24].try_into().unwrap()) as usize,
            )
        } else {
            (rdbe32(&d, o + 8) as usize, rdbe32(&d, o + 12) as usize)
        };
        if off + size > d.len() {
            return Err("corrupt FAT header".into());
        }
        return Ok(d[off..off + size].to_vec());
    }
    Err("no arm64 slice in this binary".into())
}

fn rewrite_exec_path(d: &mut [u8], cmd_off: usize, cmdsize: usize, str_field: usize) {
    let str_off = rd32(d, cmd_off + str_field) as usize;
    if str_off >= cmdsize {
        return;
    }
    let start = cmd_off + str_off;
    let end = cmd_off + cmdsize;
    let s = &d[start..end];
    let len = s.iter().position(|&b| b == 0).unwrap_or(s.len());
    let current = String::from_utf8_lossy(&s[..len]).to_string();
    if let Some(rest) = current.strip_prefix("@executable_path") {
        let new = format!("@loader_path{rest}");
        let bytes = new.as_bytes();
        // Always shorter than the original, so it fits in place.
        for b in &mut d[start..end] {
            *b = 0;
        }
        d[start..start + bytes.len()].copy_from_slice(bytes);
    }
}

/// Patch a thin arm64 main executable so dyld accepts it as a dylib.
pub fn patch_main_executable(mut d: Vec<u8>) -> Result<Vec<u8>, String> {
    if d.len() < 32 || rd32(&d, 0) != MH_MAGIC_64 {
        return Err("main executable is not a 64-bit arm64 Mach-O".into());
    }
    if rd32(&d, 4) != CPU_TYPE_ARM64 {
        return Err("main executable is not arm64".into());
    }
    let ncmds = rd32(&d, 16) as usize;
    let sizeofcmds = rd32(&d, 20) as usize;
    let mut off = 32usize;
    let mut pagezero: Option<usize> = None;
    let mut text_vmaddr: Option<u64> = None;
    let mut first_section_fileoff = usize::MAX;
    let mut has_id = false;
    let mut has_sig = false;

    for _ in 0..ncmds {
        if off + 8 > d.len() {
            return Err("truncated load commands".into());
        }
        let cmd = rd32(&d, off);
        let cmdsize = rd32(&d, off + 4) as usize;
        if cmdsize < 8 || off + cmdsize > d.len() {
            return Err("corrupt load command".into());
        }
        match cmd {
            LC_SEGMENT_64 => {
                let name = &d[off + 8..off + 24];
                let name = String::from_utf8_lossy(&name[..name.iter().position(|&b| b == 0).unwrap_or(16)]).to_string();
                if name == "__PAGEZERO" {
                    pagezero = Some(off);
                } else if name == "__TEXT" {
                    text_vmaddr = Some(rd64(&d, off + 24));
                    let nsects = rd32(&d, off + 64) as usize;
                    for i in 0..nsects {
                        let so = off + 72 + i * 80;
                        if so + 80 > off + cmdsize {
                            break;
                        }
                        let fo = rd32(&d, so + 48) as usize;
                        if fo > 0 && fo < first_section_fileoff {
                            first_section_fileoff = fo;
                        }
                    }
                }
            }
            LC_ENCRYPTION_INFO_64 => {
                if rd32(&d, off + 16) != 0 {
                    return Err("This IPA is encrypted (an App Store copy). Use a decrypted IPA.".into());
                }
            }
            LC_ID_DYLIB => has_id = true,
            LC_CODE_SIGNATURE => has_sig = true,
            LC_RPATH => rewrite_exec_path(&mut d, off, cmdsize, 8),
            LC_LOAD_DYLIB | LC_LOAD_WEAK_DYLIB | LC_REEXPORT_DYLIB | LC_LOAD_UPWARD_DYLIB
            | LC_LAZY_LOAD_DYLIB => rewrite_exec_path(&mut d, off, cmdsize, 8),
            _ => {}
        }
        off += cmdsize;
    }

    // MH_EXECUTE -> MH_DYLIB, not position-independent-executable any more
    wr32(&mut d, 12, MH_DYLIB);
    let flags = rd32(&d, 24);
    wr32(&mut d, 24, (flags & !0x0020_0000) | 0x0010_0000); // clear MH_PIE, set MH_NO_REEXPORTED_DYLIBS

    if let (Some(pz), Some(text)) = (pagezero, text_vmaddr) {
        if text >= 0x4000 {
            wr64(&mut d, pz + 24, text - 0x4000); // vmaddr
            wr64(&mut d, pz + 32, 0x4000); // vmsize
        }
    }

    if !has_id {
        let name = b"@rpath/AirCardGuest.dylib\0";
        let size = (24 + name.len() + 7) & !7;
        let cmds_end = 32 + sizeofcmds;
        // keep 16 spare bytes for an LC_CODE_SIGNATURE the signer may add
        let reserve = if has_sig { 0 } else { 16 };
        if first_section_fileoff != usize::MAX && cmds_end + size + reserve <= first_section_fileoff {
            if d[cmds_end..cmds_end + size].iter().any(|&b| b != 0) {
                return Err("no free header space for LC_ID_DYLIB".into());
            }
            wr32(&mut d, cmds_end, LC_ID_DYLIB);
            wr32(&mut d, cmds_end + 4, size as u32);
            wr32(&mut d, cmds_end + 8, 24); // name offset
            wr32(&mut d, cmds_end + 12, 2); // timestamp
            wr32(&mut d, cmds_end + 16, 0x1_0000); // current version 1.0.0
            wr32(&mut d, cmds_end + 20, 0x1_0000); // compat version 1.0.0
            d[cmds_end + 24..cmds_end + 24 + name.len()].copy_from_slice(name);
            wr32(&mut d, 16, (ncmds + 1) as u32);
            wr32(&mut d, 20, (sizeofcmds + size) as u32);
        } else {
            return Err("not enough Mach-O header space to add LC_ID_DYLIB".into());
        }
    }
    Ok(d)
}

fn bundle_info(app: &Path) -> Result<plist::Dictionary, String> {
    plist::Value::from_file(app.join("Info.plist"))
        .map_err(|e| format!("Info.plist unreadable: {e}"))?
        .into_dictionary()
        .ok_or_else(|| "Info.plist is not a dictionary".to_string())
}

fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
    if let Ok(rd) = std::fs::read_dir(dir) {
        for e in rd.flatten() {
            let p = e.path();
            let Ok(ft) = e.file_type() else { continue };
            if ft.is_symlink() {
                continue;
            }
            if ft.is_dir() {
                // App extensions / watch apps cannot run in the container.
                let name = p.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                if name == "PlugIns" || name == "Watch" || name == "Extensions" || name == "_CodeSignature" {
                    continue;
                }
                walk(&p, out);
            } else if ft.is_file() {
                out.push(p);
            }
        }
    }
}

/// Patch the main executable and collect every Mach-O to sign.
pub fn prepare_bundle(app: &Path) -> Result<PreparedBundle, String> {
    let info = bundle_info(app)?;
    let exe_name = info
        .get("CFBundleExecutable")
        .and_then(|v| v.as_string())
        .ok_or_else(|| "CFBundleExecutable missing".to_string())?
        .to_string();
    let bundle_id = info
        .get("CFBundleIdentifier")
        .and_then(|v| v.as_string())
        .unwrap_or("guest")
        .to_string();
    let exe = app.join(&exe_name);

    let raw = std::fs::read(&exe).map_err(|e| format!("read {}: {e}", exe.display()))?;
    let thin = thin_arm64(raw)?;
    // Already patched (re-sign after cert renewal): filetype is MH_DYLIB.
    let patched = if thin.len() >= 16 && rd32(&thin, 0) == MH_MAGIC_64 && rd32(&thin, 12) == MH_DYLIB {
        thin
    } else {
        patch_main_executable(thin)?
    };
    std::fs::write(&exe, patched).map_err(|e| format!("write {}: {e}", exe.display()))?;

    let mut files = Vec::new();
    walk(app, &mut files);
    let mut macho_files = vec![(exe.clone(), bundle_id.clone())];
    for f in files {
        if f == exe {
            continue;
        }
        let Ok(mut head) = std::fs::File::open(&f).and_then(|mut fh| {
            use std::io::Read;
            let mut b = vec![0u8; 32];
            let n = fh.read(&mut b)?;
            b.truncate(n);
            Ok(b)
        }) else {
            continue;
        };
        if !is_macho(&head) {
            continue;
        }
        // Thin FAT frameworks too, so the signer only sees arm64.
        if rdbe32(&head, 0) == FAT_MAGIC || rdbe32(&head, 0) == FAT_MAGIC_64 {
            if let Ok(d) = std::fs::read(&f).map_err(|e| e.to_string()).and_then(thin_arm64) {
                let _ = std::fs::write(&f, d);
            }
            head.clear();
        }
        let ident = f
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "dylib".into());
        macho_files.push((f, ident));
    }
    Ok(PreparedBundle { executable: exe, macho_files })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fake_exe() -> Vec<u8> {
        // header + __PAGEZERO + __TEXT(1 section) + LC_RPATH, with header padding
        let mut d = vec![0u8; 0x4000];
        wr32(&mut d, 0, MH_MAGIC_64);
        wr32(&mut d, 4, CPU_TYPE_ARM64);
        wr32(&mut d, 12, 2); // MH_EXECUTE
        let mut off = 32;
        // __PAGEZERO
        wr32(&mut d, off, LC_SEGMENT_64);
        wr32(&mut d, off + 4, 72);
        d[off + 8..off + 18].copy_from_slice(b"__PAGEZERO");
        wr64(&mut d, off + 32, 0x1_0000_0000);
        off += 72;
        // __TEXT with one section at file offset 0x1000
        wr32(&mut d, off, LC_SEGMENT_64);
        wr32(&mut d, off + 4, 72 + 80);
        d[off + 8..off + 14].copy_from_slice(b"__TEXT");
        wr64(&mut d, off + 24, 0x1_0000_0000);
        wr32(&mut d, off + 64, 1);
        wr32(&mut d, off + 72 + 48, 0x1000);
        off += 152;
        // LC_RPATH @executable_path/Frameworks
        let s = b"@executable_path/Frameworks\0";
        let size = (12 + s.len() + 7) & !7;
        wr32(&mut d, off, LC_RPATH);
        wr32(&mut d, off + 4, size as u32);
        wr32(&mut d, off + 8, 12);
        d[off + 12..off + 12 + s.len()].copy_from_slice(s);
        off += size;
        wr32(&mut d, 16, 3);
        wr32(&mut d, 20, (off - 32) as u32);
        d
    }

    #[test]
    fn patches_exe_into_dylib() {
        let out = patch_main_executable(fake_exe()).unwrap();
        assert_eq!(rd32(&out, 12), MH_DYLIB);
        assert_eq!(rd32(&out, 16), 4);
        // pagezero moved right under __TEXT
        assert_eq!(rd64(&out, 32 + 24), 0x1_0000_0000 - 0x4000);
        assert_eq!(rd64(&out, 32 + 32), 0x4000);
        let text = String::from_utf8_lossy(&out);
        assert!(text.contains("@loader_path/Frameworks"));
        assert!(!text.contains("@executable_path"));
        assert!(text.contains("@rpath/AirCardGuest.dylib"));
    }

    #[test]
    fn refuses_encrypted() {
        let mut d = fake_exe();
        let off = 32 + rd32(&d, 20) as usize;
        wr32(&mut d, off, LC_ENCRYPTION_INFO_64);
        wr32(&mut d, off + 4, 24);
        wr32(&mut d, off + 16, 1);
        let n = rd32(&d, 16);
        wr32(&mut d, 16, n + 1);
        let s = rd32(&d, 20);
        wr32(&mut d, 20, s + 24);
        assert!(patch_main_executable(d).unwrap_err().contains("encrypted"));
    }
}
