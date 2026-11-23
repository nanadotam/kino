#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod scan;

use scan::{disk_usage, home, par_map, MB};
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, State};

/// What the last scan found. The UI only sends back ids / paths it was given;
/// anything not in here is refused, so the UI can never delete arbitrary paths.
#[derive(Default)]
struct AppState {
    targets: Mutex<HashMap<String, Vec<PathBuf>>>,
    large: Mutex<HashSet<PathBuf>>,
    snapshots: Mutex<Vec<String>>,
}

#[derive(Serialize, Clone)]
struct Item {
    id: String,
    name: String,
    note: String,
    path: Option<String>,
    bytes: u64,
    risky: bool,
}

#[derive(Serialize)]
struct AdminItem {
    id: &'static str,
    name: &'static str,
    note: String,
    bytes: Option<u64>,
}

#[derive(Serialize)]
struct ScanResult {
    items: Vec<Item>,
    trash_bytes: Option<u64>,
    admin: Vec<AdminItem>,
    free: u64,
    total: u64,
}

#[derive(Serialize, Clone)]
struct Progress {
    done: usize,
    total: usize,
    label: String,
}

#[derive(Serialize)]
struct Disk {
    free: u64,
    total: u64,
}

#[derive(Serialize)]
struct CleanResult {
    freed: u64,
}

#[derive(Serialize)]
struct LargeFile {
    path: String,
    display: String,
    name: String,
    bytes: u64,
}

#[derive(Serialize)]
struct FolderSize {
    name: String,
    bytes: u64,
}

fn tilde(p: &Path) -> String {
    let h = home();
    match p.strip_prefix(&h) {
        Ok(rest) => format!("~/{}", rest.display()),
        Err(_) => p.display().to_string(),
    }
}

fn blocking<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> impl std::future::Future<Output = Result<T, String>> {
    let h = tauri::async_runtime::spawn_blocking(f);
    async move { h.await.map_err(|e| e.to_string()) }
}

#[tauri::command]
fn disk() -> Disk {
    let (free, total) = scan::disk_space(&home());
    Disk { free, total }
}

#[tauri::command]
async fn scan_junk(app: AppHandle, state: State<'_, AppState>) -> Result<ScanResult, String> {
    let (result, targets, snaps) = blocking(move || {
        let h = home();
        let caches_dir = h.join("Library/Caches");
        let mut cache_dirs: Vec<PathBuf> = std::fs::read_dir(&caches_dir)
            .map(|rd| {
                rd.flatten()
                    .filter(|e| e.file_type().map(|t| t.is_dir()).unwrap_or(false))
                    .filter(|e| !scan::CACHE_SKIP.contains(&e.file_name().to_string_lossy().as_ref()))
                    .map(|e| e.path())
                    .collect()
            })
            .unwrap_or_default();
        cache_dirs.sort();

        // Everything we need to size, in one parallel batch.
        let mut jobs: Vec<PathBuf> = cache_dirs.clone();
        jobs.extend(scan::KNOWN.iter().map(|k| h.join(k.rel)));
        jobs.push(h.join(".Trash"));
        jobs.push(PathBuf::from("/Library/Caches"));
        jobs.push(PathBuf::from("/Library/Logs"));

        let total = jobs.len();
        let done = AtomicUsize::new(0);
        let sizes = par_map(&jobs, |p| {
            let s = disk_usage(p);
            let n = done.fetch_add(1, Ordering::Relaxed) + 1;
            let label = p.file_name().map(|f| scan::pretty_name(&f.to_string_lossy())).unwrap_or_default();
            let _ = app.emit("scan-progress", Progress { done: n, total, label });
            s
        });

        let mut items = Vec::new();
        let mut targets: HashMap<String, Vec<PathBuf>> = HashMap::new();

        // Big app caches get their own row; the rest are grouped.
        let mut big: Vec<(PathBuf, u64)> = Vec::new();
        let mut small: Vec<PathBuf> = Vec::new();
        let mut small_bytes = 0;
        for (p, &s) in cache_dirs.iter().zip(&sizes) {
            if s >= 100 * MB {
                big.push((p.clone(), s));
            } else if s > 0 {
                small.push(p.clone());
                small_bytes += s;
            }
        }
        big.sort_by(|a, b| b.1.cmp(&a.1));
        for (p, s) in big {
            let base = p.file_name().unwrap().to_string_lossy().to_string();
            let name = scan::pretty_name(&base);
            let id = format!("cache:{base}");
            items.push(Item {
                id: id.clone(),
                note: scan::app_note(&name).into(),
                name,
                path: Some(tilde(&p)),
                bytes: s,
                risky: false,
            });
            targets.insert(id, vec![p]);
        }
        if small_bytes >= MB {
            items.push(Item {
                id: "cache:small".into(),
                name: format!("Small app caches ({} apps)", small.len()),
                note: "Many apps each keeping a little temporary data. Safe to clear.".into(),
                path: Some("~/Library/Caches".into()),
                bytes: small_bytes,
                risky: false,
            });
            targets.insert("cache:small".into(), small);
        }

        let off = cache_dirs.len();
        for (i, k) in scan::KNOWN.iter().enumerate() {
            let s = sizes[off + i];
            if s < MB {
                continue;
            }
            let p = h.join(k.rel);
            items.push(Item {
                id: k.id.into(),
                name: k.name.into(),
                note: k.note.into(),
                path: Some(tilde(&p)),
                bytes: s,
                risky: k.risky,
            });
            targets.insert(k.id.into(), vec![p]);
        }

        let n = jobs.len();
        // ~/.Trash is unreadable without Full Disk Access; report "unknown" then.
        let trash_bytes = std::fs::read_dir(h.join(".Trash")).ok().map(|_| sizes[n - 3]);

        let snaps = local_snapshots();
        let mut admin = vec![
            AdminItem { id: "syscaches", name: "System-wide app caches", note: "/Library/Caches".into(), bytes: Some(sizes[n - 2]) },
            AdminItem { id: "syslogs", name: "System logs", note: "/Library/Logs".into(), bytes: Some(sizes[n - 1]) },
        ];
        if !snaps.is_empty() {
            admin.push(AdminItem {
                id: "snapshots",
                name: "Time Machine local snapshots",
                note: format!("{} on this Mac. Your real backups are not touched.", snaps.len()),
                bytes: None,
            });
        }

        let (free, total) = scan::disk_space(&h);
        (ScanResult { items, trash_bytes, admin, free, total }, targets, snaps)
    })
    .await?;

    *state.targets.lock().unwrap() = targets;
    *state.snapshots.lock().unwrap() = snaps;
    Ok(result)
}

fn local_snapshots() -> Vec<String> {
    let Ok(out) = Command::new("/usr/bin/tmutil").args(["listlocalsnapshots", "/"]).output() else {
        return vec![];
    };
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| l.trim().strip_prefix("com.apple.TimeMachine."))
        .map(|l| l.trim_end_matches(".local").to_string())
        .filter(|d| !d.is_empty() && d.chars().all(|c| c.is_ascii_digit() || c == '-'))
        .collect()
}

#[tauri::command]
async fn clean(ids: Vec<String>, state: State<'_, AppState>) -> Result<CleanResult, String> {
    let paths: Vec<PathBuf> = {
        let t = state.targets.lock().unwrap();
        ids.iter().filter_map(|id| t.get(id)).flatten().cloned().collect()
    };
    let freed = blocking(move || par_map(&paths, |p| scan::clear_dir(p)).into_iter().sum()).await?;
    Ok(CleanResult { freed })
}

/// Cleans protected system folders. macOS shows its own password dialog.
#[tauri::command]
async fn clean_admin(ids: Vec<String>, state: State<'_, AppState>) -> Result<(), String> {
    let mut cmds: Vec<String> = Vec::new();
    for id in &ids {
        match id.as_str() {
            "syscaches" => cmds.push("/usr/bin/find /Library/Caches -mindepth 1 -maxdepth 1 -exec /bin/rm -rf {} +".into()),
            "syslogs" => cmds.push("/usr/bin/find /Library/Logs -mindepth 1 -maxdepth 1 -exec /bin/rm -rf {} +".into()),
            "snapshots" => {
                // Dates were validated as [0-9-] when listed.
                for d in state.snapshots.lock().unwrap().iter() {
                    cmds.push(format!("/usr/bin/tmutil deletelocalsnapshots {d}"));
                }
            }
            _ => {}
        }
    }
    if cmds.is_empty() {
        return Ok(());
    }
    // Errors from SIP-protected files are expected; always exit 0.
    let script = format!(
        "do shell script \"{} ; true\" with administrator privileges with prompt \"Kino needs your password to clean system folders.\"",
        cmds.join(" 2>/dev/null ; ")
    );
    blocking(move || {
        let out = Command::new("/usr/bin/osascript").args(["-e", &script]).output().map_err(|e| e.to_string())?;
        if out.status.success() {
            Ok(())
        } else {
            let err = String::from_utf8_lossy(&out.stderr);
            if err.contains("-128") { Err("cancelled".into()) } else { Err(err.trim().to_string()) }
        }
    })
    .await?
}

#[tauri::command]
async fn empty_trash() -> Result<(), String> {
    blocking(|| {
        let out = Command::new("/usr/bin/osascript")
            .args(["-e", "tell application \"Finder\" to empty trash"])
            .output()
            .map_err(|e| e.to_string())?;
        if out.status.success() {
            Ok(())
        } else {
            Err("Couldn't empty the Trash. Allow Kino to control Finder in System Settings → Privacy & Security → Automation, or empty it from Finder.".into())
        }
    })
    .await?
}

#[tauri::command]
async fn find_large_files(min_mb: u64, state: State<'_, AppState>) -> Result<Vec<LargeFile>, String> {
    let found = blocking(move || {
        let h = home();
        let lib = h.join("Library");
        let trash = h.join(".Trash");
        let skip = move |p: &Path| {
            p == lib
                || p == trash
                || p.extension().is_some_and(|e| e == "photoslibrary")
                || p.file_name().is_some_and(|n| n == "node_modules" || n == ".git")
        };
        // Parallelise across top-level folders of $HOME.
        let mut roots: Vec<PathBuf> = vec![];
        let out = Mutex::new(Vec::new());
        if let Ok(rd) = std::fs::read_dir(&h) {
            for e in rd.flatten() {
                let Ok(m) = e.metadata() else { continue };
                if m.is_dir() {
                    roots.push(e.path());
                } else if m.is_file() && m.len() >= min_mb * MB {
                    out.lock().unwrap().push((e.path(), disk_usage(&e.path())));
                }
            }
        }
        par_map(&roots, |r| scan::find_large(r, min_mb * MB, &skip, &out));
        let mut v = out.into_inner().unwrap();
        v.sort_by(|a, b| b.1.cmp(&a.1));
        v.truncate(50);
        v
    })
    .await?;

    let mut set = state.large.lock().unwrap();
    set.clear();
    Ok(found
        .into_iter()
        .map(|(p, bytes)| {
            set.insert(p.clone());
            LargeFile {
                name: p.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default(),
                display: tilde(p.parent().unwrap_or(&p)),
                path: p.to_string_lossy().to_string(),
                bytes,
            }
        })
        .collect())
}

/// Moves files to the Trash (recoverable). Only files from the last large-file search.
#[tauri::command]
async fn trash_files(paths: Vec<String>, state: State<'_, AppState>) -> Result<CleanResult, String> {
    let allowed: Vec<PathBuf> = {
        let set = state.large.lock().unwrap();
        paths.into_iter().map(PathBuf::from).filter(|p| set.contains(p)).collect()
    };
    let freed = blocking(move || {
        let mut freed = 0;
        for p in &allowed {
            let s = disk_usage(p);
            if trash::delete(p).is_ok() {
                freed += s;
            }
        }
        freed
    })
    .await?;
    let mut set = state.large.lock().unwrap();
    set.retain(|p| p.exists());
    Ok(CleanResult { freed })
}

#[tauri::command]
fn reveal(path: String, state: State<'_, AppState>) -> Result<(), String> {
    let p = PathBuf::from(&path);
    if !state.large.lock().unwrap().contains(&p) {
        return Err("unknown file".into());
    }
    Command::new("/usr/bin/open").arg("-R").arg(&p).spawn().map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
fn open_storage_settings() {
    let _ = Command::new("/usr/bin/open")
        .arg("x-apple.systempreferences:com.apple.settings.Storage")
        .spawn();
}

#[tauri::command]
async fn home_usage() -> Result<Vec<FolderSize>, String> {
    blocking(|| {
        let dirs: Vec<PathBuf> = std::fs::read_dir(home())
            .map(|rd| {
                rd.flatten()
                    .filter(|e| e.file_type().map(|t| t.is_dir()).unwrap_or(false))
                    .filter(|e| !e.file_name().to_string_lossy().starts_with('.'))
                    .map(|e| e.path())
                    .collect()
            })
            .unwrap_or_default();
        let sizes = par_map(&dirs, |d| disk_usage(d));
        let mut v: Vec<FolderSize> = dirs
            .iter()
            .zip(sizes)
            .map(|(d, bytes)| FolderSize { name: d.file_name().unwrap().to_string_lossy().to_string(), bytes })
            .filter(|f| f.bytes >= MB)
            .collect();
        v.sort_by(|a, b| b.bytes.cmp(&a.bytes));
        v.truncate(12);
        v
    })
    .await
}

fn main() {
    tauri::Builder::default()
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![
            disk,
            scan_junk,
            clean,
            clean_admin,
            empty_trash,
            find_large_files,
            trash_files,
            reveal,
            open_storage_settings,
            home_usage
        ])
        .run(tauri::generate_context!())
        .expect("error while running Kino");
}
