//! Mirsa-owned minimal loader packaging. Runs only on a disposable app copy.
//! Direct injection is unchanged. No user binary is executed on the host.
use super::*;
const LOADER: &[u8] = include_bytes!("../../loader/MirsaLoader.dylib");
const NAME: &str = "MirsaLoader.dylib";
const ORDER: &str = "MirsaLoadOrder.txt";

fn safe_order_path(s: &str) -> bool {
    !s.is_empty()
        && s.len() < 1024
        && s.split('/').all(|p| {
            !p.is_empty()
                && p != "."
                && p != ".."
                && p.bytes()
                    .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
        })
}
fn root_relative(source: &str) -> Result<String> {
    let p = Path::new(source);
    let name = p
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or("Invalid tweak name")?;
    let result = match p.extension().and_then(|s| s.to_str()) {
        Some("dylib") => name.to_string(),
        Some("framework") => format!("{name}/{}", framework_executable(p)?),
        _ => return Err("Loader supports dylib and framework roots only".into()),
    };
    if !safe_order_path(&result) || name == NAME || name == ORDER {
        return Err("Unsafe or reserved loader entry".into());
    }
    Ok(result)
}
fn target_local(app: &Path, from: &Path, dep: &str) -> Result<PathBuf> {
    let p = if let Some(s) = dep.strip_prefix("@loader_path/") {
        from.parent().unwrap().join(s)
    } else if let Some(s) = dep.strip_prefix("@executable_path/") {
        app.join(s)
    } else {
        return Err(format!("Unresolved loader dependency: {dep}"));
    };
    let p = fs::canonicalize(p).map_err(err)?;
    if !p.starts_with(app) {
        return Err("Loader dependency escapes app".into());
    }
    Ok(p)
}
fn visit(
    app: &Path,
    p: &Path,
    roots: &[PathBuf],
    current: usize,
    active: &mut HashSet<PathBuf>,
    done: &mut HashSet<PathBuf>,
) -> Result<()> {
    if active.contains(p) {
        return Err("Cyclic tweak dependency is unsupported".into());
    }
    if !done.insert(p.to_path_buf()) {
        return Ok(());
    }
    active.insert(p.to_path_buf());
    let m = macho(read_macho(p)?, true)?;
    for c in &m.commands {
        if c.kind == 0xd {
            continue;
        }
        if let Some(dep) = &c.name {
            if system_dependency(dep) {
                continue;
            }
            let target = target_local(app, p, dep)?;
            if let Some(index) = roots.iter().position(|r| r == &target) {
                if index >= current {
                    return Err(
                        "Tweak depends on itself or a later root; reorder dependencies first"
                            .into(),
                    );
                }
            }
            visit(app, &target, roots, current, active, done)?;
        }
    }
    active.remove(p);
    Ok(())
}

// Existing eager loads must not initialize a managed root before our constructor.
fn reject_eager_roots(
    app: &Path,
    p: &Path,
    roots: &[PathBuf],
    seen: &mut HashSet<PathBuf>,
) -> Result<()> {
    if !seen.insert(p.to_path_buf()) {
        return Ok(());
    }
    let m = macho(read_macho(p)?, false)?;
    for c in &m.commands {
        if c.kind == 0xd {
            continue;
        }
        if let Some(dep) = &c.name {
            if system_dependency(dep) {
                continue;
            }
            let target = if let Some(s) = dep.strip_prefix("@rpath/") {
                fs::canonicalize(app.join("Frameworks").join(s)).map_err(err)?
            } else {
                target_local(app, p, dep)?
            };
            if !target.starts_with(app) {
                return Err("Eager dependency escapes app".into());
            }
            if roots.contains(&target) {
                return Err("A managed tweak is already eagerly loaded by the app".into());
            }
            reject_eager_roots(app, &target, roots, seen)?;
        }
    }
    Ok(())
}

/// JSON operation inject_loader uses the ordinary `input`, `executable`,
/// `libraries` (ordered roots) and `new_first` fields. Loader bytes are embedded,
/// never supplied by user paths. Call on a throwaway copy then sign entire app.
pub(super) fn inject_loader(
    app: &Path,
    executable: &str,
    libraries: &[String],
    first: bool,
) -> Result<()> {
    if libraries.is_empty() || libraries.len() > 64 {
        return Err("Loader requires 1–64 ordered tweaks".into());
    }
    let entries: Vec<String> = libraries
        .iter()
        .map(|s| root_relative(s))
        .collect::<Result<_>>()?;
    let mut seen = HashSet::new();
    if entries.iter().any(|s| !seen.insert(s)) {
        return Err("Duplicate loader root".into());
    }
    let app = fs::canonicalize(app).map_err(err)?;
    let mut checked = Vec::new();
    walk(&app, &mut checked)?; // reject symlinks before creating/copying anything
    let main = app.join(relative(executable)?);
    if relative(executable)?.components().count() != 1 {
        return Err("Loader target must be main app executable".into());
    }
    let frameworks = app.join("Frameworks");
    for reserved in [NAME, ORDER] {
        if fs::symlink_metadata(frameworks.join(reserved)).is_ok() {
            return Err("Existing Mirsa loader configuration; import a clean app".into());
        }
    }
    // Existing conservative injector validates thin arm64, encrypted code,
    // bounds, dependencies, resource copying and symlink rejection.
    let original_main = fs::read(&main).map_err(err)?;
    inject(&app, executable, libraries, first)?;
    let roots: Vec<PathBuf> = entries
        .iter()
        .map(|s| fs::canonicalize(frameworks.join(s)).map_err(err))
        .collect::<Result<_>>()?;
    // Temporarily inspect original main commands, not direct refs just added by inject.
    let patched_main = fs::read(&main).map_err(err)?;
    fs::write(&main, &original_main).map_err(err)?;
    let eager_check = reject_eager_roots(&app, &main, &roots, &mut HashSet::new());
    fs::write(&main, &patched_main).map_err(err)?;
    eager_check?;
    for (i, r) in roots.iter().enumerate() {
        visit(&app, r, &roots, i, &mut HashSet::new(), &mut HashSet::new())?;
    }
    let loader_m = macho(LOADER.to_vec(), true)?;
    if loader_m
        .commands
        .iter()
        .filter_map(|c| c.name.as_deref())
        .any(|s| s != "@rpath/MirsaLoader.dylib" && !system_dependency(s))
    {
        return Err("Invalid embedded loader dependency".into());
    }
    let m = macho(read_macho(&main)?, false)?;
    let root_loads: HashSet<String> = roots.iter().map(|p| relative_loader(&main, p)).collect();
    let mut commands = Vec::new();
    for c in &m.commands {
        if c.name.as_ref().is_some_and(|n| root_loads.contains(n)) {
            continue;
        }
        commands.push(c.data.clone());
    }
    let load = dylib_command(0xc, "@loader_path/Frameworks/MirsaLoader.dylib", None)?;
    if first {
        commands.insert(0, load);
    } else {
        commands.push(load);
    }
    let main_data = write_commands(m, commands)?;
    fs::write(frameworks.join(NAME), LOADER).map_err(err)?;
    fs::write(frameworks.join(ORDER), format!("{}\n", entries.join("\n"))).map_err(err)?;
    fs::write(main, main_data).map_err(err)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn manifest_paths_are_strict() {
        for s in [
            "", "/A", "../A", "A/../B", "A//B", "A/./B", "A\\B", "A\nB", "A B", "A:", "A/",
            "أ.dylib",
        ] {
            assert!(!safe_order_path(s), "{s}");
        }
        for s in ["A.dylib", "A.framework/A", "foo-bar_1.2.dylib"] {
            assert!(safe_order_path(s));
        }
    }
    #[test]
    fn embedded_loader_is_real_arm64_ios_dylib() {
        let m = macho(LOADER.to_vec(), true).unwrap();
        assert!(m.commands.iter().any(|c| c.kind == 0x19));
        assert!(m
            .commands
            .iter()
            .any(|c| c.name.as_deref() == Some("/usr/lib/libSystem.B.dylib")));
        assert!(m
            .commands
            .iter()
            .any(|c| c.kind == 0x32 && u32at(&c.data, 8).unwrap() == 2));
    }
    fn fixture(kind: u32) -> Vec<u8> {
        let mut d = vec![0u8; 4096];
        for (off, v) in [
            (0, 0xfeedfacf),
            (4, 0x0100000c),
            (12, kind),
            (16, 1),
            (20, 152),
            (32, 0x19),
            (36, 152),
            (96, 1),
            (152, 1024),
        ] {
            put32(&mut d, off, v);
        }
        d[80..88].copy_from_slice(&4096u64.to_le_bytes());
        d[144..152].copy_from_slice(&16u64.to_le_bytes());
        d
    }
    fn setup(tag: &str) -> (PathBuf, PathBuf, Vec<String>) {
        let root = std::env::temp_dir().join(format!("mirsa-loader-{}-{tag}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let app = root.join("App.app");
        fs::create_dir_all(&app).unwrap();
        fs::write(app.join("Main"), fixture(2)).unwrap();
        let libs: Vec<String> = ["A.dylib", "B.dylib"]
            .iter()
            .map(|s| {
                let p = root.join(s);
                fs::write(&p, fixture(6)).unwrap();
                p.to_string_lossy().to_string()
            })
            .collect();
        (root, app, libs)
    }
    #[test]
    fn loader_replaces_direct_refs_and_keeps_exact_order() {
        let (root, app, libs) = setup("order");
        inject_loader(&app, "Main", &libs, false).unwrap();
        let m = macho(read_macho(&app.join("Main")).unwrap(), false).unwrap();
        let loads: Vec<_> = m
            .commands
            .iter()
            .filter(|c| c.kind == 0xc)
            .map(|c| c.name.clone().unwrap())
            .collect();
        assert_eq!(loads, vec!["@loader_path/Frameworks/MirsaLoader.dylib"]);
        assert_eq!(
            fs::read_to_string(app.join("Frameworks/MirsaLoadOrder.txt")).unwrap(),
            "A.dylib\nB.dylib\n"
        );
        assert_eq!(
            fs::read(app.join("Frameworks/MirsaLoader.dylib")).unwrap(),
            LOADER
        );
        assert!(inject_loader(&app, "Main", &libs, false).is_err());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn forward_dependencies_fail_but_dependency_first_works() {
        for reverse in [false, true] {
            let (root, app, mut libs) = setup(if reverse { "dep-ok" } else { "dep-no" });
            let m = macho(fixture(6), true).unwrap();
            let mut cs: Vec<_> = m.commands.iter().map(|c| c.data.clone()).collect();
            cs.push(dylib_command(0xc, "@loader_path/B.dylib", None).unwrap());
            fs::write(&libs[0], write_commands(m, cs).unwrap()).unwrap();
            if reverse {
                libs.reverse();
            }
            assert_eq!(inject_loader(&app, "Main", &libs, false).is_ok(), reverse);
            fs::remove_dir_all(root).unwrap();
        }
    }
    #[test]
    fn duplicate_and_unsupported_arch_fail() {
        let (root, app, libs) = setup("bad");
        assert!(inject_loader(&app, "Main", &[libs[0].clone(), libs[0].clone()], false).is_err());
        let mut d = fixture(6);
        put32(&mut d, 8, 2);
        fs::write(&libs[0], d).unwrap();
        assert!(inject_loader(&app, "Main", &libs, false).is_err());
        fs::remove_dir_all(root).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn framework_directory_escape_fails_before_copy() {
        let (root, app, libs) = setup("symlink");
        std::os::unix::fs::symlink(&root, app.join("Frameworks")).unwrap();
        assert!(inject_loader(&app, "Main", &libs, false).is_err());
        assert!(!root.join(NAME).exists());
        fs::remove_dir_all(root).unwrap();
    }
}
