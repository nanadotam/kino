# Kino

A small, fast Mac app that frees up disk space by clearing the junk apps leave behind.
Native Rust backend plus the system WebView, so it's about 9 MB on disk, the download is about 3 MB, and it runs on Apple Silicon and Intel Macs (macOS 10.15+).

- **Cleanup**: shows each app's cache (Chrome, Spotify, Slack, Xcode, etc.) with its size and what it is. Tick what you want and click **Clean selected**. Risky items (iPhone backups, Xcode archives) are never pre-ticked.
- **System junk**: protected system caches, logs, and Time Machine local snapshots. macOS shows its own password prompt; Kino never sees the password.
- **Trash**: empty it in one click.
- **Large files**: finds big files in your home folder. Selected ones go to the **Trash**, so you can get them back.
- **Storage**: shows which folders in your home folder are biggest.

Nothing is deleted until you click a button and confirm.

---

## Installing on a Mac (send this part to friends)

1. Open **Kino.dmg**.
2. Drag **Kino** onto the **Applications** folder.
3. Kino isn't signed with an Apple Developer ID yet, so macOS will block it the first time. Open **Terminal** (press `⌘ Space`, type *Terminal*, press Enter), paste this and press Enter:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Kino.app
   ```

4. Open Kino from Applications or Launchpad. Done.

**Rather not use Terminal?** Try to open Kino once (it gets blocked), then go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the Kino message.

### Permissions you might see
- **"Kino would like to access files in your Documents / Downloads / Desktop"**: happens when you use *Large files* or *Storage*. Click **Allow**.
- **"Kino wants to control Finder"**: used only to empty the Trash. Click **OK**.
- **Optional:** to let Kino clean more (Safari and Mail caches, and show the Trash size), add Kino under **System Settings → Privacy & Security → Full Disk Access**.

---

## Building it yourself

Needs [Rust](https://rustup.rs) and the Xcode Command Line Tools (`xcode-select --install`).

```bash
./scripts/build-dmg.sh     # → dist/Kino.app and dist/Kino.dmg (universal)
cargo run                  # run a debug build
cargo test                 # safety tests (e.g. cleaning never follows symlinks)
```

Project layout:

| Path | What |
| --- | --- |
| `src/main.rs` | Commands the UI calls: scan, clean, trash, etc. |
| `src/scan.rs` | Folder sizing, cleaning, list of known junk locations |
| `ui/` | The interface (plain HTML/CSS/JS, shadcn-style) |
| `scripts/build-dmg.sh` | Builds, ad-hoc signs, and packages the DMG |
| `scripts/make-icon.swift` | Regenerates the app icon |
| `Kino.command` | The original Terminal version (still works) |

**Safety:** the UI can only ask the backend to clean items the scan itself found (by id). It can never pass in an arbitrary path. Cleaning empties a folder's contents and never follows symlinks out of it.

To ship without the Terminal step later, sign with a Developer ID certificate and notarize (`codesign --options runtime -s "Developer ID Application: …"` then `xcrun notarytool submit`).
