//! Filesystem helpers: sizing, cleaning, and the list of known junk locations.

use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;

pub const MB: u64 = 1_000_000;

/// Disk usage of a path in bytes (allocated blocks, like `du`). Never follows symlinks.
pub fn disk_usage(path: &Path) -> u64 {
    let meta = match fs::symlink_metadata(path) {
        Ok(m) => m,
        Err(_) => return 0,
    };
    if !meta.is_dir() {
        return meta.blocks() * 512;
    }
    let mut total = meta.blocks() * 512;
    let mut stack = vec![path.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(rd) = fs::read_dir(&dir) else { continue };
        for entry in rd.flatten() {
            let Ok(m) = entry.metadata() else { continue }; // DirEntry::metadata doesn't follow links
            total += m.blocks() * 512;
            if m.is_dir() {
                stack.push(entry.path());
            }
        }
    }
    total
}

/// Remove everything *inside* `dir` (the folder itself stays). Returns bytes freed.
pub fn clear_dir(dir: &Path) -> u64 {
    let Ok(rd) = fs::read_dir(dir) else { return 0 };
    let mut freed = 0;
    for entry in rd.flatten() {
        let p = entry.path();
        let Ok(m) = fs::symlink_metadata(&p) else { continue };
        let before = disk_usage(&p);
        let ok = if m.is_dir() {
            fs::remove_dir_all(&p).is_ok()
        } else {
            fs::remove_file(&p).is_ok()
        };
        freed += if ok {
            before
        } else {
            // Partially removed (locked/protected files); count what actually went.
            before.saturating_sub(disk_usage(&p))
        };
    }
    freed
}

/// Run `f` over `items` on all CPU cores, preserving order.
pub fn par_map<T: Sync, R: Send>(items: &[T], f: impl Fn(&T) -> R + Sync) -> Vec<R> {
    let n = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).min(items.len().max(1));
    let next = AtomicUsize::new(0);
    let out: Mutex<Vec<Option<R>>> = Mutex::new((0..items.len()).map(|_| None).collect());
    std::thread::scope(|s| {
        for _ in 0..n {
            s.spawn(|| loop {
                let i = next.fetch_add(1, Ordering::Relaxed);
                if i >= items.len() {
                    break;
                }
                let r = f(&items[i]);
                out.lock().unwrap()[i] = Some(r);
            });
        }
    });
    out.into_inner().unwrap().into_iter().map(|r| r.unwrap()).collect()
}

pub fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"))
}

/// (free, total) bytes on the volume holding `path`.
pub fn disk_space(path: &Path) -> (u64, u64) {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    let Ok(c) = CString::new(path.as_os_str().as_bytes()) else { return (0, 0) };
    let mut st: libc::statfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statfs(c.as_ptr(), &mut st) } != 0 {
        return (0, 0);
    }
    let bs = st.f_bsize as u64;
    (st.f_bavail as u64 * bs, st.f_blocks as u64 * bs)
}

/// A fixed, well-known junk location.
pub struct Known {
    pub id: &'static str,
    pub name: &'static str,
    pub note: &'static str,
    pub rel: &'static str, // relative to $HOME
    pub risky: bool,
}

pub const KNOWN: &[Known] = &[
    Known { id: "logs", name: "System & app logs", note: "Old log files nobody reads.", rel: "Library/Logs", risky: false },
    Known { id: "mail", name: "Mail attachment downloads", note: "Copies of attachments you opened. The originals stay in Mail.", rel: "Library/Containers/com.apple.mail/Data/Library/Mail Downloads", risky: false },
    Known { id: "slack", name: "Slack (extra cache)", note: "Slack re-downloads this as needed.", rel: "Library/Application Support/Slack/Cache", risky: false },
    Known { id: "slack-sw", name: "Slack (service-worker cache)", note: "Slack rebuilds this.", rel: "Library/Application Support/Slack/Service Worker/CacheStorage", risky: false },
    Known { id: "discord", name: "Discord (extra cache)", note: "Discord rebuilds this.", rel: "Library/Application Support/discord/Cache", risky: false },
    Known { id: "teams", name: "Microsoft Teams (extra cache)", note: "Teams rebuilds this.", rel: "Library/Application Support/Microsoft/Teams/Cache", risky: false },
    Known { id: "zoom", name: "Zoom (temp data)", note: "Zoom temp data. Your recordings are not stored here.", rel: "Library/Application Support/zoom.us/data", risky: false },
    Known { id: "npm", name: "npm cache", note: "Developer package cache. Re-downloads when needed.", rel: ".npm/_cacache", risky: false },
    Known { id: "derived", name: "Xcode build leftovers", note: "Xcode rebuilds this. Often many GB.", rel: "Library/Developer/Xcode/DerivedData", risky: false },
    Known { id: "devsupport", name: "Xcode iOS device support", note: "Re-created when you plug in a device.", rel: "Library/Developer/Xcode/iOS DeviceSupport", risky: false },
    Known { id: "simcache", name: "iOS Simulator caches", note: "Rebuilt automatically.", rel: "Library/Developer/CoreSimulator/Caches", risky: false },
    Known { id: "ipsw", name: "Old iPhone/iPad software updates", note: "Downloaded iOS update files you no longer need.", rel: "Library/iTunes/iPhone Software Updates", risky: false },
    Known { id: "backups", name: "iPhone/iPad backups", note: "Full phone backups. Only delete if you don't need them.", rel: "Library/Application Support/MobileSync/Backup", risky: true },
    Known { id: "archives", name: "Xcode Archives", note: "Past app builds you may need to re-submit. Only if you're sure.", rel: "Library/Developer/Xcode/Archives", risky: true },
];

/// Caches we leave alone: clearing them mid-sync can confuse iCloud.
pub const CACHE_SKIP: &[&str] = &["com.apple.bird", "CloudKit", "com.apple.cloudd"];

/// Bundle-id-ish folder name -> friendly app name.
pub fn pretty_name(base: &str) -> String {
    let s = base;
    let after = |p: &str| s.strip_prefix(p).unwrap_or(s).to_string();
    if s.starts_with("com.google.Chrome") || s == "Google" { return "Google Chrome".into(); }
    if s.starts_with("com.apple.Safari") { return "Safari".into(); }
    if s.starts_with("company.thebrowser.") { return "Arc".into(); }
    if s.starts_with("org.mozilla.") || s == "Firefox" { return "Firefox".into(); }
    if s.starts_with("com.brave.") || s == "BraveSoftware" { return "Brave".into(); }
    if s == "com.spotify.client" || s == "Spotify" { return "Spotify".into(); }
    if s.starts_with("com.tinyspeck.slackmacgap") { return "Slack".into(); }
    if s.starts_with("com.hnc.Discord") || s == "discord" { return "Discord".into(); }
    if s == "us.zoom.xos" || s == "zoom.us" { return "Zoom".into(); }
    if s.to_lowercase().starts_with("com.microsoft.teams") { return "Microsoft Teams".into(); }
    if s.starts_with("com.microsoft.") { return format!("Microsoft {}", after("com.microsoft.")); }
    if s.starts_with("com.adobe.") { return format!("Adobe {}", after("com.adobe.")); }
    if s == "Adobe" { return "Adobe".into(); }
    if s.starts_with("com.apple.") { return format!("Apple · {}", after("com.apple.")); }
    if s.starts_with("com.whatsapp.") || s == "WhatsApp" { return "WhatsApp".into(); }
    if s.starts_with("com.openai.") { return "ChatGPT".into(); }
    if s == "Homebrew" { return "Homebrew (developer tools)".into(); }
    if s == "pip" { return "pip (Python installs)".into(); }
    for p in ["com.", "org.", "io.", "net.", "co.", "app."] {
        if let Some(rest) = s.strip_prefix(p) {
            return rest.to_string();
        }
    }
    s.to_string()
}

pub fn app_note(name: &str) -> &'static str {
    match name {
        "Google Chrome" | "Safari" | "Firefox" | "Brave" | "Arc" =>
            "Saved web pages and images so sites load faster. You stay logged in; sites reload a bit slower once.",
        "Spotify" => "Songs and artwork kept for faster playback. Playlists are safe; offline downloads may need re-downloading.",
        "Slack" | "Discord" | "Zoom" | "Microsoft Teams" =>
            "Images, files and thumbnails from chats and calls. Re-downloaded when you open them again.",
        "WhatsApp" => "Previews and media thumbnails. Your chats are not stored here.",
        _ => "Temporary files this app saved to run faster. It rebuilds them on its own.",
    }
}

/// Recursively find regular files >= `min` bytes under `root`, skipping `skip(path)`.
pub fn find_large(root: &Path, min: u64, skip: &(dyn Fn(&Path) -> bool + Sync), out: &Mutex<Vec<(PathBuf, u64)>>) {
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        if skip(&dir) {
            continue;
        }
        let Ok(rd) = fs::read_dir(&dir) else { continue };
        for entry in rd.flatten() {
            let Ok(m) = entry.metadata() else { continue };
            if m.is_dir() {
                stack.push(entry.path());
            } else if m.is_file() {
                let sz = m.blocks() * 512;
                if sz >= min {
                    out.lock().unwrap().push((entry.path(), sz));
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clear_dir_empties_but_never_follows_symlinks() {
        let base = std::env::temp_dir().join(format!("kino-test-{}", std::process::id()));
        let cache = base.join("cache");
        let outside = base.join("precious");
        fs::create_dir_all(cache.join("nested/deeper")).unwrap();
        fs::create_dir_all(&outside).unwrap();
        fs::write(cache.join("a.bin"), vec![1u8; 200_000]).unwrap();
        fs::write(cache.join("nested/deeper/b.bin"), vec![2u8; 50_000]).unwrap();
        fs::write(outside.join("keep.txt"), b"do not delete").unwrap();
        std::os::unix::fs::symlink(&outside, cache.join("link-to-dir")).unwrap();
        std::os::unix::fs::symlink(outside.join("keep.txt"), cache.join("link-to-file")).unwrap();

        let before = disk_usage(&cache);
        assert!(before >= 250_000);
        let freed = clear_dir(&cache);
        assert!(freed >= 250_000 && freed <= before);

        assert!(cache.is_dir(), "the folder itself stays");
        assert_eq!(fs::read_dir(&cache).unwrap().count(), 0, "contents removed");
        assert_eq!(fs::read(outside.join("keep.txt")).unwrap(), b"do not delete");
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn names() {
        assert_eq!(pretty_name("com.spotify.client"), "Spotify");
        assert_eq!(pretty_name("com.apple.Safari"), "Safari");
        assert_eq!(pretty_name("io.example"), "example");
    }
}
