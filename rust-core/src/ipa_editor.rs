//! Bounded pre-install archive tooling and conservative Mach-O injection.
//! Never executes package scripts or loads user code into Mirsa.
//! Mach-O rewriting only consumes verified zero header padding; no relocation.
#[path = "load_control.rs"]
mod load_control;
use serde::Deserialize;
use std::{
    collections::{BTreeMap, HashSet},
    ffi::{c_char, CStr, CString},
    fs::{self, File},
    io::{self, Cursor, Read, Seek, SeekFrom},
    path::{Component, Path, PathBuf},
};
use zip::{write::SimpleFileOptions, ZipArchive, ZipWriter};

type Result<T> = std::result::Result<T, String>;
const FILE_LIMIT: u64 = 512 * 1024 * 1024;
const TOTAL_LIMIT: u64 = 4 * 1024 * 1024 * 1024;
const ENTRY_LIMIT: usize = 100_000;
fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

fn relative(name: &str) -> Result<PathBuf> {
    if name.is_empty() || name.contains(['\\', '\0', ':']) || name.len() > 4096 {
        return Err("Unsafe archive path".into());
    }
    let p = Path::new(name);
    if p.components().count() > 64
        || p.components()
            .any(|c| !matches!(c, Component::Normal(_) | Component::CurDir))
    {
        return Err(format!("Unsafe archive path: {name}"));
    }
    let p: PathBuf = p
        .components()
        .filter_map(|c| match c {
            Component::Normal(s) => Some(s),
            _ => None,
        })
        .collect();
    if p.as_os_str().is_empty() {
        return Err("Empty archive path".into());
    }
    Ok(p)
}

fn fresh_dir(path: &Path) -> Result<()> {
    if path.exists() {
        return Err("Extraction destination must not exist".into());
    }
    fs::create_dir_all(path).map_err(err)
}
fn checked_write<R: Read>(mut reader: R, path: &Path, size: u64, mode: u32) -> Result<()> {
    if size > FILE_LIMIT {
        return Err("Archive entry exceeds 512 MiB".into());
    }
    if let Some(p) = path.parent() {
        fs::create_dir_all(p).map_err(err)?;
    }
    let mut out = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(err)?;
    let copied = io::copy(&mut reader.by_ref().take(size + 1), &mut out).map_err(err)?;
    if copied != size {
        return Err("Truncated or oversized archive entry".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(
            path,
            fs::Permissions::from_mode(if mode & 0o111 != 0 { 0o755 } else { 0o644 }),
        )
        .map_err(err)?;
    }
    Ok(())
}
fn extract_zip(input: &Path, dest: &Path) -> Result<()> {
    let mut zip = ZipArchive::new(File::open(input).map_err(err)?).map_err(err)?;
    if zip.len() > ENTRY_LIMIT {
        return Err("Too many archive entries".into());
    }
    // Validate every entry before writing anything.
    let mut seen = HashSet::new();
    let mut total = 0u64;
    for i in 0..zip.len() {
        let f = zip.by_index(i).map_err(err)?;
        let p = relative(f.name())?;
        if !seen.insert(p.to_string_lossy().to_lowercase()) {
            return Err("Duplicate archive path".into());
        }
        let mode = f.unix_mode().unwrap_or(0o100644);
        if !matches!(mode & 0o170000, 0 | 0o040000 | 0o100000) {
            return Err("Archive links and special files are not supported".into());
        }
        total = total.checked_add(f.size()).ok_or("Archive too large")?;
        if f.size() > FILE_LIMIT || total > TOTAL_LIMIT {
            return Err("Archive size limit exceeded".into());
        }
    }
    fresh_dir(dest)?;
    let result = (|| {
        for i in 0..zip.len() {
            let mut f = zip.by_index(i).map_err(err)?;
            let out = dest.join(relative(f.name())?);
            if f.is_dir() {
                fs::create_dir_all(out).map_err(err)?;
            } else {
                let size = f.size();
                let mode = f.unix_mode().unwrap_or(0o644);
                checked_write(&mut f, &out, size, mode)?;
            }
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_dir_all(dest);
    }
    result
}
pub(crate) fn walk(root: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
    walk_depth(root, out, 0)
}
fn walk_depth(root: &Path, out: &mut Vec<PathBuf>, depth: usize) -> Result<()> {
    if depth > 64 {
        return Err("Directory tree is too deep".into());
    }
    for entry in fs::read_dir(root).map_err(err)? {
        let p = entry.map_err(err)?.path();
        let m = fs::symlink_metadata(&p).map_err(err)?;
        if m.file_type().is_symlink() || !(m.is_dir() || m.is_file()) {
            return Err("Links and special files are unsupported".into());
        }
        if out.len() >= ENTRY_LIMIT {
            return Err("Too many files".into());
        }
        out.push(p.clone());
        if m.is_dir() {
            walk_depth(&p, out, depth + 1)?;
        }
    }
    Ok(())
}
fn pack(root: &Path, output: &Path) -> Result<()> {
    let mut files = Vec::new();
    walk(root, &mut files)?;
    files.sort();
    if !root.join("Payload").is_dir() {
        return Err("Payload is missing".into());
    }
    let file = fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(output)
        .map_err(err)?;
    let mut zip = ZipWriter::new(file);
    let result = (|| {
        for p in files {
            let name = p
                .strip_prefix(root)
                .map_err(err)?
                .to_str()
                .ok_or("Invalid filename")?
                .replace('\\', "/");
            let m = fs::metadata(&p).map_err(err)?;
            #[cfg(unix)]
            let mode = {
                use std::os::unix::fs::PermissionsExt;
                m.permissions().mode()
            };
            #[cfg(not(unix))]
            let mode = 0o755;
            let opt = SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated)
                .unix_permissions(mode & 0o777);
            if m.is_dir() {
                zip.add_directory(format!("{name}/"), opt).map_err(err)?;
            } else {
                zip.start_file(name, opt).map_err(err)?;
                io::copy(&mut File::open(&p).map_err(err)?, &mut zip).map_err(err)?;
            }
        }
        zip.finish().map_err(err)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(output);
    }
    result
}

/// Debian ar envelope only. tar/gzip/xz decoding uses maintained libraries.
fn deb_data(input: &Path) -> Result<(String, Vec<u8>)> {
    if fs::metadata(input).map_err(err)?.len() > FILE_LIMIT {
        return Err("Package too large".into());
    }
    let mut f = File::open(input).map_err(err)?;
    let length = f.metadata().map_err(err)?.len();
    let mut magic = [0u8; 8];
    f.read_exact(&mut magic).map_err(err)?;
    if &magic != b"!<arch>\n" {
        return Err("Not a Debian ar package".into());
    }
    let mut offset = 8u64;
    let mut found = None;
    while offset < length {
        if length - offset < 60 {
            return Err("Truncated ar header".into());
        }
        f.seek(SeekFrom::Start(offset)).map_err(err)?;
        let mut h = [0u8; 60];
        f.read_exact(&mut h).map_err(err)?;
        if &h[58..60] != b"`\n" {
            return Err("Invalid ar header".into());
        }
        let name = std::str::from_utf8(&h[..16])
            .map_err(err)?
            .trim()
            .trim_end_matches('/')
            .to_string();
        let size: u64 = std::str::from_utf8(&h[48..58])
            .map_err(err)?
            .trim()
            .parse()
            .map_err(err)?;
        let end = offset
            .checked_add(60)
            .and_then(|n| n.checked_add(size))
            .ok_or("ar size overflow")?;
        if end > length {
            return Err("Truncated ar member".into());
        }
        if name.starts_with("data.tar") {
            if found.is_some() {
                return Err("Duplicate data archive".into());
            }
            if size > 128 * 1024 * 1024 {
                return Err("Compressed Debian payload exceeds 128 MiB".into());
            }
            let mut data = vec![0; size as usize];
            f.read_exact(&mut data).map_err(err)?;
            found = Some((name, data));
        }
        offset = end.checked_add(size & 1).ok_or("ar size overflow")?;
        if offset > length {
            return Err("Truncated ar padding".into());
        }
    }
    found.ok_or("Debian package has no data archive".into())
}
fn extract_deb(input: &Path, dest: &Path) -> Result<()> {
    let (name, data) = deb_data(input)?;
    let reader: Box<dyn Read> = match name.as_str() {
        "data.tar" => Box::new(Cursor::new(data)),
        "data.tar.gz" => Box::new(flate2::read::GzDecoder::new(Cursor::new(data))),
        "data.tar.xz" => Box::new(lzma_rust2::XzReader::new_mem_limit(
            Cursor::new(data),
            false,
            64 * 1024,
        )),
        _ => {
            return Err(format!(
                "Unsupported Debian compression: {name}. Use data.tar, .gz or .xz."
            ))
        }
    };
    fresh_dir(dest)?;
    let result = (|| {
        let mut archive = tar::Archive::new(reader.take(TOTAL_LIMIT + 1));
        let mut total = 0u64;
        let mut count = 0;
        let mut seen = HashSet::new();
        for entry in archive.entries().map_err(err)? {
            count += 1;
            if count > ENTRY_LIMIT {
                return Err("Too many tar entries".into());
            }
            let mut entry = entry.map_err(err)?;
            let raw = entry.path().map_err(err)?.to_string_lossy().to_string();
            // tar root './' is a common harmless directory entry.
            if (raw == "." || raw == "./") && entry.header().entry_type().is_dir() {
                continue;
            }
            let rel = relative(&raw)?;
            if !seen.insert(rel.to_string_lossy().to_lowercase()) {
                return Err("Duplicate tar path".into());
            }
            let kind = entry.header().entry_type();
            if !kind.is_dir() && !kind.is_file() {
                return Err("Debian links and special files are not supported".into());
            }
            let size = entry.size();
            total = total.checked_add(size).ok_or("Package too large")?;
            if size > FILE_LIMIT || total > TOTAL_LIMIT {
                return Err("Package expansion limit exceeded".into());
            }
            let out = dest.join(rel);
            if kind.is_dir() {
                fs::create_dir_all(out).map_err(err)?;
            } else {
                let mode = entry.header().mode().map_err(err)?;
                checked_write(&mut entry, &out, size, mode)?;
            }
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_dir_all(dest);
    }
    result
}

fn u32at(d: &[u8], o: usize) -> Result<u32> {
    Ok(u32::from_le_bytes(
        d.get(o..o + 4)
            .ok_or("Truncated Mach-O")?
            .try_into()
            .map_err(err)?,
    ))
}
fn u64at(d: &[u8], o: usize) -> Result<u64> {
    Ok(u64::from_le_bytes(
        d.get(o..o + 8)
            .ok_or("Truncated Mach-O")?
            .try_into()
            .map_err(err)?,
    ))
}
fn put32(d: &mut [u8], o: usize, n: u32) {
    d[o..o + 4].copy_from_slice(&n.to_le_bytes());
}
#[derive(Clone)]
struct Command {
    kind: u32,
    data: Vec<u8>,
    name: Option<String>,
}
struct Mach {
    data: Vec<u8>,
    commands: Vec<Command>,
    first_data: usize,
    subtype: u32,
}
fn read_macho(p: &Path) -> Result<Vec<u8>> {
    if fs::metadata(p).map_err(err)?.len() > 128 * 1024 * 1024 {
        return Err("Mach-O exceeds the 128 MiB editing limit".into());
    }
    fs::read(p).map_err(err)
}
fn macho(d: Vec<u8>, dylib: bool) -> Result<Mach> {
    // Thin arm64 only is intentional. Do not silently discard architecture slices.
    if d.len() < 32 || u32at(&d, 0)? != 0xfeedfacf || u32at(&d, 4)? != 0x0100000c {
        return Err(
            "Only thin arm64 Mach-O is supported; FAT/32-bit binaries must be thinned first".into(),
        );
    }
    let subtype = u32at(&d, 8)? & 0x00ffffff;
    if subtype != 0 {
        return Err("arm64e and specialized CPU subtypes are not supported".into());
    }
    let ft = u32at(&d, 12)?;
    if (dylib && ft != 6) || (!dylib && ft != 2 && ft != 6) {
        return Err("Wrong Mach-O file type".into());
    }
    let n = u32at(&d, 16)? as usize;
    let end = 32usize
        .checked_add(u32at(&d, 20)? as usize)
        .ok_or("Mach-O size overflow")?;
    if end > d.len() || n > 65536 {
        return Err("Invalid Mach-O load table".into());
    }
    let mut o = 32;
    let mut commands = Vec::new();
    let mut first_data = d.len();
    let mut has_data_section = false;
    for _ in 0..n {
        if o + 8 > end {
            return Err("Truncated load command".into());
        }
        let kind = u32at(&d, o)?;
        let size = u32at(&d, o + 4)? as usize;
        if size < 8 || size % 8 != 0 || size > end - o {
            return Err("Malformed Mach-O command".into());
        }
        let c = d[o..o + size].to_vec();
        if kind == 0x21 || kind == 0x2c {
            if size < 20 || u32at(&c, 16)? != 0 {
                return Err("Encrypted App Store binary is unsupported".into());
            }
        }
        if kind == 0x19 {
            if size < 72 {
                return Err("Short segment command".into());
            }
            let fileoff = usize::try_from(u64at(&c, 40)?).map_err(err)?;
            let filesize = usize::try_from(u64at(&c, 48)?).map_err(err)?;
            if fileoff.checked_add(filesize).ok_or("Segment overflow")? > d.len() {
                return Err("Segment extends outside file".into());
            }
            if fileoff > 0 && filesize > 0 {
                first_data = first_data.min(fileoff);
            }
            let sections = u32at(&c, 64)? as usize;
            if sections > (size - 72) / 80 {
                return Err("Truncated section table".into());
            }
            for i in 0..sections {
                let s = 72 + i * 80;
                let off = u32at(&c, s + 48)? as usize;
                let flags = u32at(&c, s + 64)? & 0xff;
                let len = usize::try_from(u64at(&c, s + 40)?).map_err(err)?;
                // Zero-fill sections do not occupy bytes on disk.
                if !matches!(flags, 1 | 0xc | 0x12) && len > 0 {
                    if off < end || off.checked_add(len).ok_or("Section overflow")? > d.len() {
                        return Err("Invalid section range".into());
                    }
                    first_data = first_data.min(off);
                    has_data_section = true;
                }
            }
        }
        // Every supported command carrying on-disk offsets constrains padding.
        let mut region = |off: usize, len: usize| -> Result<()> {
            if len > 0 {
                if off < end || off.checked_add(len).ok_or("Data range overflow")? > d.len() {
                    return Err("Load command data overlaps header or exceeds file".into());
                }
                first_data = first_data.min(off);
            }
            Ok(())
        };
        match kind {
            0x2 => {
                if size < 24 {
                    return Err("Short symbol table command".into());
                }
                region(
                    u32at(&c, 8)? as usize,
                    (u32at(&c, 12)? as usize)
                        .checked_mul(16)
                        .ok_or("Symbols overflow")?,
                )?;
                region(u32at(&c, 16)? as usize, u32at(&c, 20)? as usize)?;
            }
            0xb => {
                if size < 80 {
                    return Err("Short dynamic symbol table".into());
                }
                for (offset, width) in [(32, 8usize), (40, 56), (48, 4), (56, 4), (64, 8), (72, 8)]
                {
                    region(
                        u32at(&c, offset)? as usize,
                        (u32at(&c, offset + 4)? as usize)
                            .checked_mul(width)
                            .ok_or("Symbol range overflow")?,
                    )?;
                }
            }
            0x22 | 0x80000022 => {
                if size < 48 {
                    return Err("Short dyld info command".into());
                }
                for offset in [8, 16, 24, 32, 40] {
                    region(u32at(&c, offset)? as usize, u32at(&c, offset + 4)? as usize)?;
                }
            }
            0x1d | 0x1e | 0x26 | 0x29 | 0x2b | 0x2e | 0x80000033 | 0x80000034 | 0x36 => {
                if size < 16 {
                    return Err("Short linkedit command".into());
                }
                region(u32at(&c, 8)? as usize, u32at(&c, 12)? as usize)?;
            }
            0x2c => {
                if size < 24 {
                    return Err("Short encryption command".into());
                }
                region(u32at(&c, 8)? as usize, u32at(&c, 12)? as usize)?;
            }
            // No on-disk data references, or segments already checked above.
            0x19 | 0xc | 0xd | 0x80000018 | 0x8000001f | 0x80000023 | 0x20 | 0xe | 0xf | 0x10
            | 0x11 | 0x12 | 0x13 | 0x14 | 0x15 | 0x1b | 0x8000001c | 0x24 | 0x25 | 0x27
            | 0x80000028 | 0x2a | 0x2f | 0x30 | 0x32 => {}
            _ => {
                return Err(format!(
                    "Unsupported Mach-O load command 0x{kind:x}; refusing unsafe header edits"
                ))
            }
        }
        let name = if matches!(
            kind,
            0xc | 0xd | 0x80000018 | 0x8000001f | 0x80000023 | 0x20
        ) {
            if size < 24 {
                return Err("Short dylib command".into());
            }
            let at = u32at(&c, 8)? as usize;
            if at < 24 || at >= size {
                return Err("Invalid dylib name offset".into());
            }
            let tail = &c[at..];
            let len = tail
                .iter()
                .position(|&b| b == 0)
                .ok_or("Unterminated dylib name")?;
            Some(std::str::from_utf8(&tail[..len]).map_err(err)?.to_string())
        } else {
            None
        };
        commands.push(Command {
            kind,
            data: c,
            name,
        });
        o += size;
    }
    if !has_data_section {
        return Err("Mach-O has no verifiable file-backed section".into());
    }
    if o != end || first_data < end {
        return Err("Invalid load table size".into());
    }
    Ok(Mach {
        data: d,
        commands,
        first_data,
        subtype,
    })
}
/// Inspect encrypted slices without changing architecture or deployment targets.
/// This also protects metadata-only edits of universal IPAs.
pub(crate) fn unencrypted(d: &[u8]) -> Result<()> {
    if d.len() < 32 {
        return Err("Truncated Mach-O".into());
    }
    let magic = u32::from_be_bytes(d[0..4].try_into().map_err(err)?);
    if magic == 0xcafebabe || magic == 0xcafebabf {
        let count = u32::from_be_bytes(d[4..8].try_into().map_err(err)?) as usize;
        let stride = if magic == 0xcafebabf { 32 } else { 20 };
        if count == 0 || count > 128 || 8 + count * stride > d.len() {
            return Err("Invalid FAT table".into());
        }
        let mut ranges = Vec::new();
        for i in 0..count {
            let a = 8 + i * stride;
            let (off, len) = if stride == 32 {
                (
                    u64::from_be_bytes(d[a + 8..a + 16].try_into().map_err(err)?),
                    u64::from_be_bytes(d[a + 16..a + 24].try_into().map_err(err)?),
                )
            } else {
                (
                    u32::from_be_bytes(d[a + 8..a + 12].try_into().map_err(err)?) as u64,
                    u32::from_be_bytes(d[a + 12..a + 16].try_into().map_err(err)?) as u64,
                )
            };
            let off = usize::try_from(off).map_err(err)?;
            let len = usize::try_from(len).map_err(err)?;
            let end = off.checked_add(len).ok_or("FAT overflow")?;
            if off < 8 + count * stride
                || len < 32
                || end > d.len()
                || ranges.iter().any(|&(a, b)| off < b && end > a)
            {
                return Err("Invalid FAT slice bounds".into());
            }
            ranges.push((off, end));
            // Nested FAT containers are not valid architecture slices.
            if u32at(d, off)? != 0xfeedfacf {
                return Err("Unsupported FAT slice format".into());
            }
            unencrypted(&d[off..end])?;
        }
        return Ok(());
    }
    if u32at(d, 0)? != 0xfeedfacf {
        return Err("Only 64-bit little-endian Mach-O is supported".into());
    }
    let count = u32at(d, 16)? as usize;
    let end = 32usize
        .checked_add(u32at(d, 20)? as usize)
        .ok_or("Mach-O table overflow")?;
    if count > 65536 || end > d.len() {
        return Err("Invalid load table".into());
    }
    let mut at = 32;
    for _ in 0..count {
        if at + 8 > end {
            return Err("Truncated load command".into());
        }
        let kind = u32at(d, at)?;
        let size = u32at(d, at + 4)? as usize;
        if size < 8 || size % 8 != 0 || size > end - at {
            return Err("Malformed load command".into());
        }
        if kind == 0x21 || kind == 0x2c {
            if size < 20 || u32at(d, at + 16)? != 0 {
                return Err(
                    "Encrypted App Store binaries cannot be edited. Import a decrypted IPA.".into(),
                );
            }
        }
        at += size;
    }
    if at != end {
        return Err("Invalid command count".into());
    }
    Ok(())
}
fn dylib_command(kind: u32, name: &str, original: Option<&[u8]>) -> Result<Vec<u8>> {
    if name.contains('\0') || name.len() > 4096 {
        return Err("Invalid dylib load path".into());
    }
    let size = (24 + name.len() + 1 + 7) & !7;
    let mut d = vec![0; size];
    if let Some(old) = original {
        d[..24].copy_from_slice(&old[..24]);
    }
    put32(&mut d, 0, kind);
    put32(&mut d, 4, size as u32);
    put32(&mut d, 8, 24);
    d[24..24 + name.len()].copy_from_slice(name.as_bytes());
    Ok(d)
}
fn write_commands(mut m: Mach, commands: Vec<Vec<u8>>) -> Result<Vec<u8>> {
    let old_end = 32 + u32at(&m.data, 20)? as usize;
    let new_size: usize = commands.iter().map(Vec::len).sum();
    let new_end = 32 + new_size;
    // Reserve space for the signer's signature command and container LC_ID_DYLIB.
    if new_end
        .max(old_end)
        .checked_add(96)
        .ok_or("Header overflow")?
        > m.first_data
        || m.data[old_end..new_end.max(old_end) + 96]
            .iter()
            .any(|&b| b != 0)
    {
        return Err(
            "Not enough zero Mach-O header padding. Binary relocation is not supported.".into(),
        );
    }
    m.data[32..old_end.max(new_end)].fill(0);
    let mut o = 32;
    for c in &commands {
        m.data[o..o + c.len()].copy_from_slice(c);
        o += c.len();
    }
    put32(&mut m.data, 16, commands.len() as u32);
    put32(&mut m.data, 20, new_size as u32);
    Ok(m.data)
}

fn system_dependency(s: &str) -> bool {
    let lower = s.to_lowercase();
    if ["substrate", "ellekit", "substitute", "libhooker"]
        .iter()
        .any(|n| lower.contains(n))
    {
        return false;
    }
    s.starts_with("/System/Library/") || s.starts_with("/usr/lib/")
}
fn relative_loader(from: &Path, to: &Path) -> String {
    let a: Vec<_> = from.parent().unwrap().components().collect();
    let b: Vec<_> = to.components().collect();
    let same = a.iter().zip(&b).take_while(|(x, y)| x == y).count();
    let mut parts = vec!["@loader_path".to_string()];
    parts.extend((same..a.len()).map(|_| "..".to_string()));
    parts.extend(
        b[same..]
            .iter()
            .map(|c| c.as_os_str().to_string_lossy().to_string()),
    );
    parts.join("/")
}
fn dependency_target(
    dep: &str,
    current: &Path,
    app: &Path,
    names: &BTreeMap<String, PathBuf>,
) -> Result<PathBuf> {
    if let Some(rest) = dep.strip_prefix("@loader_path/") {
        let p = current.parent().unwrap().join(rest);
        if let Ok(p) = fs::canonicalize(p) {
            if p.starts_with(app) && p.is_file() {
                return Ok(p);
            }
        }
    }
    if let Some(rest) = dep.strip_prefix("@executable_path/") {
        let p = app.join(rest);
        if let Ok(p) = fs::canonicalize(p) {
            if p.starts_with(app) && p.is_file() {
                return Ok(p);
            }
        }
    }
    let suffix = dep.strip_prefix("@rpath/").unwrap_or(dep);
    let candidate = app.join("Frameworks").join(suffix);
    if let Ok(p) = fs::canonicalize(candidate) {
        if p.starts_with(app) && p.is_file() {
            return Ok(p);
        }
    }
    let base = Path::new(dep)
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or("Invalid dependency path")?;
    names.get(base).cloned().ok_or_else(|| format!("Missing dependency: {dep}. Import its compatible dylib/framework yourself; Mirsa never bundles CydiaSubstrate or ElleKit."))
}
fn copy_tree(from: &Path, to: &Path) -> Result<()> {
    let m = fs::symlink_metadata(from).map_err(err)?;
    if m.file_type().is_symlink() {
        return Err("Framework symlinks are unsupported".into());
    }
    if m.is_dir() {
        fs::create_dir(to).map_err(err)?;
        for e in fs::read_dir(from).map_err(err)? {
            let e = e.map_err(err)?;
            copy_tree(&e.path(), &to.join(e.file_name()))?;
        }
    } else if m.is_file() {
        fs::copy(from, to).map_err(err)?;
    } else {
        return Err("Special files are unsupported".into());
    }
    Ok(())
}
fn framework_executable(framework: &Path) -> Result<String> {
    let info = framework.join("Info.plist");
    if fs::metadata(&info).map_err(err)?.len() > 4 * 1024 * 1024 {
        return Err("Framework Info.plist exceeds 4 MiB".into());
    }
    let p = plist::Value::from_file(info).map_err(err)?;
    let name = p
        .as_dictionary()
        .and_then(|d| d.get("CFBundleExecutable"))
        .and_then(plist::Value::as_string)
        .ok_or("Framework has no executable")?;
    let path = relative(name)?;
    if path.components().count() != 1 {
        return Err("Invalid framework executable".into());
    }
    Ok(name.to_string())
}

/// Operates exclusively on a disposable app copy. Swift swaps it in only after repacking succeeds.

/// Lists dylib load commands of a thin or FAT (first slice) 64-bit Mach-O. Read-only, bounded.
fn dependencies(path: &Path) -> Result<Vec<String>> {
    let all = read_macho(path)?;
    let mut d: &[u8] = &all;
    if d.len() >= 8 && (u32at(d, 0)? == 0xcafebabe || u32at(d, 0)? == 0xbebafeca) {
        // FAT header is big-endian; use first slice only.
        let big = |o: usize| -> Result<usize> { Ok(u32::from_be_bytes(d.get(o..o + 4).ok_or("Truncated FAT header")?.try_into().unwrap()) as usize) };
        let (off, size) = (big(16)?, big(20)?);
        d = d.get(off..off.checked_add(size).ok_or("FAT overflow")?).ok_or("Invalid FAT slice")?;
    }
    if d.len() < 32 || u32at(d, 0)? != 0xfeedfacf { return Err("Only 64-bit little-endian Mach-O is supported".into()); }
    let count = u32at(d, 16)? as usize;
    let end = 32usize.checked_add(u32at(d, 20)? as usize).ok_or("Mach-O table overflow")?;
    if count > 65536 || end > d.len() { return Err("Invalid load table".into()); }
    let (mut at, mut out) = (32usize, Vec::new());
    for _ in 0..count {
        if at + 8 > end { return Err("Truncated load command".into()); }
        let kind = u32at(d, at)?;
        let size = u32at(d, at + 4)? as usize;
        if size < 8 || size % 8 != 0 || size > end - at { return Err("Malformed load command".into()); }
        if matches!(kind, 0xc | 0x18 | 0x1f | 0x80000018 | 0x8000001f) {
            let name_off = u32at(d, at + 8)? as usize;
            if name_off < 24 || name_off >= size { return Err("Invalid dylib name".into()); }
            let raw = &d[at + name_off..at + size];
            let len = raw.iter().position(|&b| b == 0).ok_or("Unterminated dylib name")?;
            if len > 4096 { return Err("Dylib name too long".into()); }
            out.push(String::from_utf8_lossy(&raw[..len]).into_owned());
        }
        at += size;
    }
    if out.len() > 4096 { out.truncate(4096); }
    Ok(out)
}
fn inject(app: &Path, executable: &str, libraries: &[String], first: bool) -> Result<()> {
    let app = fs::canonicalize(app).map_err(err)?;
    let ex = relative(executable)?;
    if ex.components().count() != 1 {
        return Err("Invalid executable name".into());
    }
    let main = app.join(ex);
    let frameworks = app.join("Frameworks");
    fs::create_dir_all(&frameworks).map_err(err)?;
    let mut roots = Vec::new();
    for path in libraries {
        let source = Path::new(path);
        let name = source.file_name().ok_or("Invalid tweak filename")?;
        let target = frameworks.join(name);
        if target.exists() {
            return Err(format!(
                "Frameworks filename collision: {}",
                target.display()
            ));
        }
        match source.extension().and_then(|s| s.to_str()) {
            Some("dylib") => {
                copy_tree(source, &target)?;
                roots.push(target);
            }
            Some("framework") => {
                let exe = framework_executable(source)?;
                copy_tree(source, &target)?;
                roots.push(target.join(exe));
            }
            _ => return Err("Select a dylib or framework executable package".into()),
        }
    }
    let mut files = Vec::new();
    walk(&frameworks, &mut files)?;
    let mut names = BTreeMap::new();
    for p in files.iter().filter(|p| p.is_file()) {
        let base = p.file_name().unwrap().to_string_lossy().to_string();
        // Only Mach-O dependencies are candidates. Non-code resources stay untouched.
        let mut f = File::open(p).map_err(err)?;
        let mut head = [0u8; 4];
        if f.read_exact(&mut head).is_ok()
            && (head == [0xcf, 0xfa, 0xed, 0xfe]
                || head == [0xca, 0xfe, 0xba, 0xbe]
                || head == [0xca, 0xfe, 0xba, 0xbf])
        {
            if names.insert(base, p.clone()).is_some() {
                return Err("Ambiguous dependency executable name".into());
            }
        }
    }
    let mut patches = BTreeMap::new();
    let mut total_code = 0usize;
    let mut queue = roots.clone();
    let mut seen = HashSet::new();
    while let Some(p) = queue.pop() {
        let p = fs::canonicalize(p).map_err(err)?;
        if !p.starts_with(&app) {
            return Err("Dependency escapes app".into());
        }
        if !seen.insert(p.clone()) {
            continue;
        }
        let m = macho(read_macho(&p)?, true)?;
        let mut commands = Vec::new();
        for c in &m.commands {
            if c.kind != 0xd {
                if let Some(dep) = &c.name {
                    if !system_dependency(dep) {
                        let target = dependency_target(dep, &p, &app, &names)?;
                        queue.push(target.clone());
                        commands.push(dylib_command(
                            c.kind,
                            &relative_loader(&p, &target),
                            Some(&c.data),
                        )?);
                        continue;
                    }
                }
            }
            commands.push(c.data.clone());
        }
        let data = write_commands(m, commands)?;
        total_code = total_code
            .checked_add(data.len())
            .ok_or("Code size overflow")?;
        if total_code > 256 * 1024 * 1024 {
            return Err("Injected code exceeds the 256 MiB editing limit".into());
        }
        patches.insert(p, data);
    }
    let m = macho(read_macho(&main)?, false)?;
    let _ = m.subtype; // already checked, keep type data explicit
    let mut commands: Vec<_> = m.commands.iter().map(|c| c.data.clone()).collect();
    let mut added: Vec<Vec<u8>> = Vec::new();
    for root in roots {
        let load = relative_loader(&main, &root);
        if !m
            .commands
            .iter()
            .any(|c| c.name.as_deref() == Some(load.as_str()))
        {
            added.push(dylib_command(0xc, &load, None)?);
        }
    }
    // Optional: injected tweaks load before the app's own libraries (list order kept).
    if first { added.extend(commands); commands = added; } else { commands.extend(added); }
    patches.insert(main, write_commands(m, commands)?);
    for (path, data) in patches {
        fs::write(path, data).map_err(err)?;
    }
    Ok(())
}

#[derive(Deserialize)]
struct Request {
    operation: String,
    #[serde(default)]
    input: String,
    #[serde(default)]
    output: String,
    #[serde(default)]
    executable: String,
    #[serde(default)]
    libraries: Vec<String>,
    #[serde(default)]
    new_first: bool,
    #[serde(default)]
    private_key: String,
    #[serde(default)]
    certificate: String,
    #[serde(default)]
    profile: String,
    #[serde(flatten)]
    signing_options: crate::personal_sign::Options,
}
fn run(r: Request) -> Result<crate::personal_sign::Verification> {
    match r.operation.as_str() {
        #[cfg(test)]
        "__test_worker_panic" => panic!("synthetic worker panic"),
        "personal_sign" => return crate::personal_sign::sign_with_options(Path::new(&r.input), Path::new(&r.profile), &r.private_key, &r.certificate, &r.signing_options),
        "validate" => unencrypted(&read_macho(Path::new(&r.input))?),
        "extract" => extract_zip(Path::new(&r.input), Path::new(&r.output)),
        "pack" => pack(Path::new(&r.input), Path::new(&r.output)),
        "deb" => extract_deb(Path::new(&r.input), Path::new(&r.output)),
        "dependencies" => {
            let list = dependencies(Path::new(&r.input))?;
            let json = serde_json::to_vec(&list).map_err(err)?;
            let out = Path::new(&r.output);
            if out.parent().is_none() { return Err("Invalid output".into()); }
            fs::write(out, json).map_err(err)
        }
        "inject_loader" => load_control::inject_loader(Path::new(&r.input), &r.executable, &r.libraries, r.new_first),
        "inject" => inject(Path::new(&r.input), &r.executable, &r.libraries, r.new_first),
        _ => Err("Unknown editor operation".into()),
    }.map(|_| crate::personal_sign::Verification::default())
}
// The entire synchronous editor/signing path must leave Swift's ~544 KiB
// cooperative stack. Runtime::block_on polls its root future on THIS thread;
// configuring only Tokio worker stacks cannot fix the observed stack guard hit.
const EDITOR_STACK_BYTES: usize = 16 * 1024 * 1024;
fn editor_worker<T: Send + 'static>(work: impl FnOnce() -> Result<T> + Send + 'static) -> Result<T> {
    let worker = std::thread::Builder::new().name("mirsa-editor".into())
        .stack_size(EDITOR_STACK_BYTES).spawn(work)
        .map_err(|_| "تعذّر بدء عامل التوقيع. جرّب مرة تانية.".to_owned())?;
    worker.join().unwrap_or_else(|_| Err("توقّف عامل التوقيع بسبب بيانات غير صالحة.".into()))
}
/// Returns an owned UTF-8 JSON result; release via existing al_string_free.
/// # Safety
/// request must point to a valid NUL-terminated UTF-8 JSON string.
#[no_mangle]
pub unsafe extern "C" fn al_ipa_editor_run(request: *const c_char) -> *mut c_char {
    editor_run_with_progress(request, None)
}
/// Callback and context remain valid until this synchronous call returns.
/// A zero callback return cancels safely at the next signed-bundle boundary.
#[no_mangle]
pub unsafe extern "C" fn al_ipa_editor_run_progress(
    request: *const c_char,
    callback: crate::signing_progress::Callback,
    context: *mut std::ffi::c_void,
) -> *mut c_char {
    editor_run_with_progress(request, Some(crate::signing_progress::Sink { callback, context: context as usize }))
}
unsafe fn editor_run_with_progress(request: *const c_char, sink: Option<crate::signing_progress::Sink>) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        if request.is_null() { return Err("Missing request".into()); }
        let text = CStr::from_ptr(request).to_str().map_err(err)?;
        if text.len() > 1024 * 1024 { return Err("Request too large".into()); }
        // Own all input before crossing threads. No borrowed C pointer escapes.
        let owned = text.to_owned();
        editor_worker(move || crate::signing_progress::scope(sink, || run(serde_json::from_str(&owned).map_err(err)?)))
    }).unwrap_or_else(|_| Err("تعذّر قراءة طلب التوقيع.".into()));
    let json = match result {
        Ok(status) => serde_json::json!({"ok":true,"profile_verification":status.profile_verification,"warnings":status.warnings,"device_authorization":status.device_authorization}),
        Err(e) => serde_json::json!({"ok":false,"error":e}),
    };
    CString::new(json.to_string()).unwrap().into_raw()
}
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dependencies_lists_dylib_loads_and_rejects_malformed() {
        let c1 = dylib_command(0xc, "@rpath/Foo.framework/Foo", None).unwrap();
        let c2 = dylib_command(0x80000018, "/usr/lib/libz.1.dylib", None).unwrap();
        let mut d = vec![0u8; 4096];
        d[0..4].copy_from_slice(&0xfeedfacfu32.to_le_bytes());
        d[4..8].copy_from_slice(&0x0100000cu32.to_le_bytes());
        d[12..16].copy_from_slice(&2u32.to_le_bytes());
        d[16..20].copy_from_slice(&2u32.to_le_bytes());
        d[20..24].copy_from_slice(&((c1.len() + c2.len()) as u32).to_le_bytes());
        d[32..32 + c1.len()].copy_from_slice(&c1);
        d[32 + c1.len()..32 + c1.len() + c2.len()].copy_from_slice(&c2);
        let dir = std::env::temp_dir().join(format!("mirsa-deps-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let p = dir.join("main");
        fs::write(&p, &d).unwrap();
        assert_eq!(dependencies(&p).unwrap(), vec!["@rpath/Foo.framework/Foo", "/usr/lib/libz.1.dylib"]);
        // truncated table and garbage fail closed
        d[20..24].copy_from_slice(&0xffffffu32.to_le_bytes());
        fs::write(&p, &d).unwrap();
        assert!(dependencies(&p).is_err());
        fs::write(&p, b"garbage-garbage-garbage-garbage-garbage").unwrap();
        assert!(dependencies(&p).is_err());
        fs::remove_dir_all(dir).unwrap();
    }
    fn ffi_json(request: serde_json::Value) -> serde_json::Value {
        let request = CString::new(request.to_string()).unwrap();
        let ptr = unsafe { al_ipa_editor_run(request.as_ptr()) };
        assert!(!ptr.is_null());
        let owned = unsafe { CString::from_raw(ptr) };
        serde_json::from_slice(owned.as_bytes()).unwrap()
    }
    #[test]
    fn ffi_worker_panic_becomes_arabic_json() {
        let result = ffi_json(serde_json::json!({"operation":"__test_worker_panic","input":""}));
        assert_eq!(result["ok"], false);
        assert!(result["error"].as_str().unwrap().contains("عامل التوقيع"));
    }
    #[test]
    fn ffi_signing_from_small_stack_reaches_real_pairing_parser() {
        use base64::Engine;
        use isideload_p12_keystore::{KeyStore,KeyStoreEntry,Pkcs12ImportPolicy};
        let store = KeyStore::from_pkcs12(include_bytes!("../tests/p12-fixtures/modern.p12"), "mirsa-test", Pkcs12ImportPolicy::Raw).unwrap();
        let key = store.entries().find_map(|(_, e)| if let KeyStoreEntry::PrivateKeyChain(c) = e { Some(c.key().as_der().to_vec()) } else { None }).unwrap();
        let dir = std::env::temp_dir().join(format!("mirsa-small-stack-{}",std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let pairing = dir.join("pairing.plist");
        // Structurally valid plist, deliberately missing required pairing keys.
        // Reaches both production PairingFile parsers and fails before networking.
        fs::write(&pairing, b"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>").unwrap();
        let b64 = base64::engine::general_purpose::STANDARD;
        let request = serde_json::json!({"operation":"personal_sign","input":dir.to_str().unwrap(),"private_key":b64.encode(key),"certificate":b64.encode(include_bytes!("../tests/p12-fixtures/leaf.der")),"pairing_path":pairing.to_str().unwrap()});
        let result = std::thread::Builder::new().stack_size(544 * 1024).spawn(move || {
            // Also proves the FFI worker leaves an already entered runtime.
            let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
            rt.block_on(async { ffi_json(request) })
        }).unwrap().join().unwrap();
        assert_eq!(result["ok"], false);
        assert!(result["error"].as_str().unwrap().contains("neither a valid Lockdown"), "{result}");
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn production_worker_has_separate_large_stack() {
        let caller = std::thread::current().id();
        let id = editor_worker(move || {
            assert_eq!(std::thread::current().name(), Some("mirsa-editor"));
            // Touch a frame larger than the observed cooperative stack.
            #[inline(never)]
            fn touch() -> usize {
                let mut frame = [0u8; 1024 * 1024];
                for (i, byte) in frame.iter_mut().enumerate() { *byte = (i % 251) as u8; }
                std::hint::black_box(&frame)[700_000] as usize
            }
            assert!(touch() > 0);
            Ok(std::thread::current().id())
        }).unwrap();
        assert_ne!(caller, id);
    }
    #[test]
    fn ffi_invalid_requests_return_error_json() {
        unsafe fn response(request: *const c_char) -> serde_json::Value {
            let ptr = al_ipa_editor_run(request);
            assert!(!ptr.is_null());
            let owned = CString::from_raw(ptr);
            serde_json::from_slice(owned.as_bytes()).unwrap()
        }
        assert_eq!(unsafe { response(std::ptr::null()) }["ok"], false);
        for text in ["{", "null", "{}", r#"{"operation":"personal_sign","input":"/nonexistent/mirsa-test-app"}"#] {
            let request = CString::new(text).unwrap();
            let result = unsafe { response(request.as_ptr()) };
            assert_eq!(result["ok"], false);
            assert!(result["error"].as_str().is_some());
        }
    }
    fn fixture() -> Vec<u8> {
        let mut d = vec![0u8; 4096];
        put32(&mut d, 0, 0xfeedfacf);
        put32(&mut d, 4, 0x0100000c);
        put32(&mut d, 12, 2);
        put32(&mut d, 16, 1);
        put32(&mut d, 20, 152);
        put32(&mut d, 32, 0x19);
        put32(&mut d, 36, 152);
        d[40..46].copy_from_slice(b"__TEXT");
        d[80..88].copy_from_slice(&4096u64.to_le_bytes());
        put32(&mut d, 96, 1);
        d[144..152].copy_from_slice(&16u64.to_le_bytes());
        put32(&mut d, 152, 1024);
        d
    }
    #[test]
    fn inject_copies_and_connects_real_dylib() {
        let root = super::integration_tests::temporary();
        let app = root.join("App.app");
        fs::create_dir(&app).unwrap();
        fs::write(app.join("Main"), fixture()).unwrap();
        let mut dylib = fixture();
        put32(&mut dylib, 12, 6);
        fs::write(root.join("Tweak.dylib"), dylib).unwrap();
        inject(
            &app,
            "Main",
            &[root.join("Tweak.dylib").to_string_lossy().to_string()],
            false,
        )
        .unwrap();
        let out = macho(fs::read(app.join("Main")).unwrap(), false).unwrap();
        assert!(out
            .commands
            .iter()
            .any(|c| c.kind == 0xc
                && c.name.as_deref() == Some("@loader_path/Frameworks/Tweak.dylib")));
        assert!(app.join("Frameworks/Tweak.dylib").is_file());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn encrypted_validation_and_fat_bounds() {
        assert!(unencrypted(&fixture()).is_ok());
        let mut d = fixture();
        put32(&mut d, 16, 2);
        put32(&mut d, 20, 176);
        put32(&mut d, 184, 0x2c);
        put32(&mut d, 188, 24);
        put32(&mut d, 200, 1);
        assert!(unencrypted(&d).is_err());
        let mut fat = vec![0; 4096];
        fat[..4].copy_from_slice(&0xcafebabeu32.to_be_bytes());
        fat[4..8].copy_from_slice(&1u32.to_be_bytes());
        fat[16..20].copy_from_slice(&4000u32.to_be_bytes());
        fat[20..24].copy_from_slice(&4096u32.to_be_bytes());
        assert!(unencrypted(&fat).is_err());
    }
    #[test]
    fn linkedit_overlap_rejected() {
        let mut d = fixture();
        put32(&mut d, 16, 2);
        put32(&mut d, 20, 168);
        put32(&mut d, 184, 0x26);
        put32(&mut d, 188, 16);
        put32(&mut d, 192, 50);
        put32(&mut d, 196, 10);
        assert!(macho(d, false).is_err());
    }
    #[test]
    fn rejects_paths() {
        for p in ["../bad", "/absolute", "a/../../b", "C:/bad", "a\\b", "x\0z"] {
            assert!(relative(p).is_err(), "{p}");
        }
        assert_eq!(relative("./a/b").unwrap(), PathBuf::from("a/b"));
    }
    #[test]
    fn genuine_load_command() {
        let m = macho(fixture(), false).unwrap();
        let mut cs = m
            .commands
            .iter()
            .map(|c| c.data.clone())
            .collect::<Vec<_>>();
        cs.push(dylib_command(0xc, "@loader_path/Frameworks/Test.dylib", None).unwrap());
        let out = write_commands(m, cs).unwrap();
        let parsed = macho(out, false).unwrap();
        assert_eq!(parsed.commands.len(), 2);
        assert_eq!(parsed.commands[1].kind, 0xc);
        assert_eq!(
            parsed.commands[1].name.as_deref(),
            Some("@loader_path/Frameworks/Test.dylib")
        );
    }
    #[test]
    fn rejects_bad_macho() {
        for len in 0..190 {
            assert!(macho(fixture()[..len].to_vec(), false).is_err());
        }
        let mut d = fixture();
        put32(&mut d, 36, 8);
        assert!(macho(d, false).is_err());
        let mut d = fixture();
        put32(&mut d, 16, u32::MAX);
        assert!(macho(d, false).is_err());
        let mut d = fixture();
        put32(&mut d, 152, 100);
        assert!(macho(d, false).is_err());
        let mut d = fixture();
        put32(&mut d, 8, 2);
        assert!(macho(d, false).is_err());
    }
    #[test]
    fn refuses_encrypted() {
        let mut d = fixture();
        put32(&mut d, 16, 2);
        put32(&mut d, 20, 176);
        put32(&mut d, 184, 0x2c);
        put32(&mut d, 188, 24);
        put32(&mut d, 200, 1);
        assert!(macho(d, false).unwrap_err_string().contains("Encrypted"));
    }
    trait ErrorString {
        fn unwrap_err_string(self) -> String;
    }
    impl ErrorString for Result<Mach> {
        fn unwrap_err_string(self) -> String {
            match self {
                Err(e) => e,
                Ok(_) => panic!("expected error"),
            }
        }
    }
    #[test]
    fn refuses_nonzero_padding() {
        let mut d = fixture();
        d[190] = 1;
        let m = macho(d, false).unwrap();
        let mut c = m
            .commands
            .iter()
            .map(|c| c.data.clone())
            .collect::<Vec<_>>();
        c.push(dylib_command(0xc, "@loader_path/Test.dylib", None).unwrap());
        assert!(write_commands(m, c).is_err());
    }
}

#[cfg(test)]
mod integration_tests {
    use super::*;
    use std::io::Write;
    pub(super) fn temporary() -> PathBuf {
        let p = std::env::temp_dir().join(format!(
            "mirsa-editor-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&p).unwrap();
        p
    }
    fn zip_file(path: &Path, names: &[(&str, &[u8])]) {
        let mut z = ZipWriter::new(File::create(path).unwrap());
        for (name, data) in names {
            z.start_file(*name, SimpleFileOptions::default()).unwrap();
            z.write_all(data).unwrap();
        }
        z.finish().unwrap();
    }
    fn tar_data(name: &str) -> Vec<u8> {
        let mut t = tar::Builder::new(Vec::new());
        let mut h = tar::Header::new_gnu();
        h.set_size(4);
        h.set_mode(0o755);
        h.set_cksum();
        t.append_data(&mut h, name, Cursor::new(b"test")).unwrap();
        t.into_inner().unwrap()
    }
    fn ar_data(name: &str, data: &[u8]) -> Vec<u8> {
        let mut ar = b"!<arch>\n".to_vec();
        let h = format!(
            "{:<16}{:<12}{:<6}{:<6}{:<8}{:<10}`\n",
            name,
            0,
            0,
            0,
            "100644",
            data.len()
        );
        assert_eq!(h.len(), 60);
        ar.extend(h.as_bytes());
        ar.extend(data);
        if data.len() % 2 != 0 {
            ar.push(b'\n');
        }
        ar
    }
    #[test]
    fn archive_roundtrip_preserves_edits() {
        let t = temporary();
        let original = t.join("original.ipa");
        zip_file(
            &original,
            &[
                ("Payload/Test.app/Info.plist", b"original"),
                ("Payload/Test.app/Test", b"binary"),
            ],
        );
        let x = t.join("x");
        extract_zip(&original, &x).unwrap();
        fs::write(x.join("Payload/Test.app/Info.plist"), b"edited").unwrap();
        let output = t.join("edited.ipa");
        pack(&x, &output).unwrap();
        let y = t.join("y");
        extract_zip(&output, &y).unwrap();
        assert_eq!(
            fs::read(y.join("Payload/Test.app/Info.plist")).unwrap(),
            b"edited"
        );
        assert_eq!(
            fs::read(y.join("Payload/Test.app/Test")).unwrap(),
            b"binary"
        );
        fs::remove_dir_all(t).unwrap();
    }
    #[test]
    fn rejects_zip_traversal_before_writes() {
        let t = temporary();
        let ipa = t.join("bad.ipa");
        zip_file(
            &ipa,
            &[("Payload/App.app/ok", b"hello"), ("../escaped", b"bad")],
        );
        let out = t.join("x");
        assert!(extract_zip(&ipa, &out).is_err());
        assert!(!out.exists());
        assert!(!t.join("escaped").exists());
        fs::remove_dir_all(t).unwrap();
    }
    #[test]
    fn rejects_zip_case_collisions() {
        let t = temporary();
        let ipa = t.join("bad.ipa");
        zip_file(
            &ipa,
            &[
                ("Payload/App.app/Test", b"a"),
                ("Payload/App.app/test", b"b"),
            ],
        );
        assert!(extract_zip(&ipa, &t.join("x")).is_err());
        fs::remove_dir_all(t).unwrap();
    }
    #[test]
    fn rejects_zip_symlink() {
        let t = temporary();
        let ipa = t.join("bad.ipa");
        let mut z = ZipWriter::new(File::create(&ipa).unwrap());
        z.add_symlink(
            "Payload/App.app/link",
            "../../../outside",
            SimpleFileOptions::default(),
        )
        .unwrap();
        z.finish().unwrap();
        assert!(extract_zip(&ipa, &t.join("x")).is_err());
        fs::remove_dir_all(t).unwrap();
    }
    #[test]
    fn rejects_extract_over_existing_destination() {
        let t = temporary();
        let ipa = t.join("ok.ipa");
        zip_file(&ipa, &[("a", b"a")]);
        let out = t.join("x");
        fs::create_dir(&out).unwrap();
        fs::write(out.join("keep"), b"keep").unwrap();
        assert!(extract_zip(&ipa, &out).is_err());
        assert_eq!(fs::read(out.join("keep")).unwrap(), b"keep");
        fs::remove_dir_all(t).unwrap();
    }
    #[test]
    fn deb_plain_and_gzip() {
        let t = temporary();
        let tar = tar_data("./Library/MobileSubstrate/DynamicLibraries/Test.dylib");
        let deb = t.join("test.deb");
        fs::write(&deb, ar_data("data.tar/", &tar)).unwrap();
        extract_deb(&deb, &t.join("plain")).unwrap();
        assert_eq!(
            fs::read(t.join("plain/Library/MobileSubstrate/DynamicLibraries/Test.dylib")).unwrap(),
            b"test"
        );
        let mut gzip = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        gzip.write_all(&tar).unwrap();
        let gzip = gzip.finish().unwrap();
        fs::write(&deb, ar_data("data.tar.gz/", &gzip)).unwrap();
        extract_deb(&deb, &t.join("gzip")).unwrap();
        assert!(t
            .join("gzip/Library/MobileSubstrate/DynamicLibraries/Test.dylib")
            .is_file());
        fs::remove_dir_all(t).unwrap();
    }
    #[test]
    fn deb_special_and_truncated_rejected() {
        let t = temporary();
        let mut tar = tar::Builder::new(Vec::new());
        let mut h = tar::Header::new_gnu();
        h.set_mode(0o777);
        h.set_entry_type(tar::EntryType::Symlink);
        h.set_size(0);
        h.set_cksum();
        tar.append_link(&mut h, "a", "../../escaped").unwrap();
        let deb = t.join("bad.deb");
        fs::write(&deb, ar_data("data.tar/", &tar.into_inner().unwrap())).unwrap();
        assert!(extract_deb(&deb, &t.join("x")).is_err());
        assert!(!t.join("x").exists());
        fs::write(&deb, b"!<arch>\ntruncated").unwrap();
        assert!(deb_data(&deb).is_err());
        fs::remove_dir_all(t).unwrap();
    }
    #[test]
    fn missing_hook_runtime_is_explicit() {
        let t = temporary();
        let app = t.join("Test.app");
        fs::create_dir(&app).unwrap();
        let app = fs::canonicalize(app).unwrap();
        let binary = app.join("Frameworks/Tweak.dylib");
        let e = dependency_target(
            "/usr/lib/libsubstrate.dylib",
            &binary,
            &app,
            &BTreeMap::new(),
        )
        .unwrap_err();
        assert!(e.contains("Missing dependency"));
        assert!(!system_dependency("/usr/lib/libsubstrate.dylib"));
        assert!(!system_dependency(
            "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"
        ));
        assert!(system_dependency("/usr/lib/libobjc.A.dylib"));
        fs::remove_dir_all(t).unwrap();
    }
    #[test]
    fn dependency_paths_are_loader_relative() {
        assert_eq!(
            relative_loader(
                Path::new("/App/Frameworks/A.framework/A"),
                Path::new("/App/Frameworks/B.dylib")
            ),
            "@loader_path/../B.dylib"
        );
        assert_eq!(
            relative_loader(
                Path::new("/App/App"),
                Path::new("/App/Frameworks/A.framework/A")
            ),
            "@loader_path/Frameworks/A.framework/A"
        );
    }
    #[test]
    fn malformed_input_never_panics() {
        for len in 0..1024usize {
            let d: Vec<u8> = (0..len)
                .map(|i| ((i.wrapping_mul(137) + len) % 256) as u8)
                .collect();
            assert!(std::panic::catch_unwind(|| unencrypted(&d)).is_ok());
            assert!(std::panic::catch_unwind(|| macho(d, false)).is_ok());
        }
    }
}
