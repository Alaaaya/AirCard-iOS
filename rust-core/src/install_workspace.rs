//! An install owns its snapshot and extraction until AFC completes.
//! Never derive cleanup ownership from a caller path or an "_extracted" suffix.
use std::{fs::{self, File, OpenOptions}, io, path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering}};
static NEXT: AtomicU64 = AtomicU64::new(0);
pub(crate) struct InstallWorkspace { root: PathBuf }
impl InstallWorkspace {
    pub(crate) fn new() -> Result<Self, String> {
        Self::under(&std::env::temp_dir())
    }
    fn under(parent: &Path) -> Result<Self, String> {
        fs::create_dir_all(parent).map_err(|e| format!("Preparing install workspace: {e}"))?;
        loop {
            let serial = NEXT.fetch_add(1, Ordering::Relaxed);
            let name = format!("mirsa-install-{}-{}-{}", std::process::id(),
                std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default().as_nanos(), serial);
            let root = parent.join(name);
            match fs::create_dir(&root) {
                Ok(()) => return Ok(Self { root }),
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(format!("Preparing install workspace: {e}")),
            }
        }
    }
    pub(crate) fn root(&self) -> &Path { &self.root }
    pub(crate) fn snapshot(&self, source: &Path) -> Result<PathBuf, String> {
        // Open first, not exists-then-copy. An atomic reimport may replace the
        // canonical path while this descriptor still owns the previous bytes.
        let mut input = File::open(source).map_err(|e| {
            if e.kind() == io::ErrorKind::NotFound && source.extension().and_then(|s| s.to_str()) == Some("ipa") { "MIRSA_SOURCE_IPA_MISSING".into() }
            else { format!("Reading source app: {e}") }
        })?;
        let meta = input.metadata().map_err(|e| format!("Reading source app: {e}"))?;
        if meta.is_dir() { return Err("Preparing app archive: expected an IPA file".into()); }
        if !meta.is_file() || meta.len() == 0 || meta.len() > 4 * 1024 * 1024 * 1024 {
            return Err("Preparing app archive: invalid source file size or type".into());
        }
        let partial = self.root.join("source.partial");
        let mut output = OpenOptions::new().write(true).create_new(true).open(&partial)
            .map_err(|e| format!("Preparing app snapshot: {e}"))?;
        use std::io::Read;
        let copied = io::copy(&mut input.by_ref().take(meta.len() + 1), &mut output)
            .map_err(|e| format!("Reading source app: {e}"))?;
        if copied != meta.len() { return Err("Reading source app: file changed during preparation".into()); }
        output.sync_all().map_err(|e| format!("Saving app snapshot: {e}"))?;
        drop(output);
        let ready = self.root.join("source.ipa");
        fs::rename(partial, &ready).map_err(|e| format!("Publishing app snapshot: {e}"))?;
        Ok(ready)
    }
    pub(crate) fn single_app(&self, extraction: &Path) -> Result<PathBuf, String> {
        let mut apps = Vec::new();
        for entry in fs::read_dir(extraction.join("Payload"))
            .map_err(|e| format!("Preparing extracted app: {e}"))? {
            let entry = entry.map_err(|e| format!("Preparing extracted app: {e}"))?;
            if entry.file_type().map_err(|e| format!("Preparing extracted app: {e}"))?.is_dir()
                && entry.path().extension().and_then(|e| e.to_str()) == Some("app") {
                apps.push(entry.path());
            }
        }
        if apps.len() != 1 { return Err("Preparing extracted app: expected exactly one app".into()); }
        Ok(apps.remove(0))
    }
}
impl Drop for InstallWorkspace {
    fn drop(&mut self) { let _ = fs::remove_dir_all(&self.root); }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> InstallWorkspace { InstallWorkspace::new().unwrap() }
    #[test] fn missing_source_is_explicit_before_install() {
        let w=fixture();
        assert_eq!(w.snapshot(&w.root.join("missing.ipa")).unwrap_err(),"MIRSA_SOURCE_IPA_MISSING");
    }
    #[test] fn snapshot_survives_original_cleanup() {
        let parent=fixture(); let source=parent.root.join("a.ipa"); fs::write(&source,b"archive").unwrap();
        let w=fixture(); let ready=w.snapshot(&source).unwrap(); fs::remove_file(source).unwrap();
        assert_eq!(fs::read(ready).unwrap(),b"archive");
    }
    #[test] fn overlapping_same_basename_cleanup_is_owned() {
        let parent=fixture(); let source=parent.root.join("original.ipa"); fs::write(&source,b"archive").unwrap();
        let a=fixture(); let b=fixture(); let ap=a.snapshot(&source).unwrap(); let bp=b.snapshot(&source).unwrap();
        drop(a); assert!(!ap.exists()); assert_eq!(fs::read(bp).unwrap(),b"archive"); assert!(source.exists());
    }
    #[test] fn stale_stage_recovers_same_process_without_restart() {
        let parent=fixture(); let source=parent.root.join("a.ipa"); fs::write(&source,b"archive").unwrap();
        { let old=fixture(); old.snapshot(&source).unwrap(); }
        let fresh=fixture(); assert_eq!(fs::read(fresh.snapshot(&source).unwrap()).unwrap(),b"archive");
    }
    #[test] fn reimport_uses_current_canonical_file() {
        let parent=fixture(); let source=parent.root.join("a.ipa"); fs::write(&source,b"old").unwrap();
        let old=fixture(); let oldfile=old.snapshot(&source).unwrap();
        let next=parent.root.join("new.ipa"); fs::write(&next,b"new").unwrap(); fs::rename(next,&source).unwrap();
        let fresh=fixture(); assert_eq!(fs::read(fresh.snapshot(&source).unwrap()).unwrap(),b"new");
        assert_eq!(fs::read(oldfile).unwrap(),b"old");
    }
    #[test] fn preparation_enoent_is_not_missing_source() {
        let parent=fixture(); let source=parent.root.join("a.ipa"); fs::write(&source,b"archive").unwrap();
        let w=fixture(); fs::remove_dir_all(w.root()).unwrap();
        let error=w.snapshot(&source).unwrap_err();
        assert!(error.starts_with("Preparing app snapshot:")); assert!(!error.contains("MIRSA_SOURCE"));
        let fresh=fixture(); assert!(fresh.snapshot(&source).is_ok());
    }
    #[test] fn unique_workspaces_across_threads() {
        let jobs: Vec<_>=(0..8).map(|_| std::thread::spawn(fixture)).collect();
        let stages:Vec<_>=jobs.into_iter().map(|j|j.join().unwrap()).collect();
        let names:std::collections::HashSet<_>=stages.iter().map(|w|w.root()).collect();
        assert_eq!(names.len(),8);
    }
    #[test] fn incomplete_file_is_never_published() {
        let parent=fixture(); let source=parent.root.join("a.ipa"); fs::write(&source,b"").unwrap();
        let w=fixture(); assert!(w.snapshot(&source).is_err()); assert!(!w.root.join("source.ipa").exists());
        fs::write(&source,b"ready").unwrap(); assert!(w.snapshot(&source).is_ok());
    }
    #[test] fn delayed_atomic_publication_is_observed_on_next_preparation() {
        let parent=fixture(); let source=parent.root.join("a.ipa"); let pending=parent.root.join("a.partial");
        fs::write(&pending,b"ready").unwrap();
        let first=fixture(); assert!(first.snapshot(&source).is_err());
        fs::rename(pending,&source).unwrap();
        let next=fixture(); assert_eq!(fs::read(next.snapshot(&source).unwrap()).unwrap(),b"ready");
    }
}
