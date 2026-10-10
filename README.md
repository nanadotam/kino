# Kino

A simple, safe way to free up space on your Mac. Kino finds the junk that apps leave behind, shows you what it is and how big it is, and **asks before deleting anything.**

No installs. No Python. Nothing to set up.

---

## Before you start

1. **Quit your apps** (Chrome, Safari, Slack, Spotify). More can be cleaned when they're closed.
2. Have your **Mac login password** ready. You'll only need it for one optional step.

---

## How to open it

**Double-click `Kino.command`.**

A Terminal window opens and Kino starts. That's it.

> **First time only:** if macOS says it *"can't be opened because Apple cannot check it"*, **right-click** the file, choose **Open**, then click **Open** again. After this one time, double-clicking works normally.

---

## What happens next

### 1. A one-minute tour

Kino explains what "cache" means and how to answer. You answer with **one key**, no Enter needed.

| Press | What it does |
|:--|:--|
| **Y** | Yes, clear it |
| **N** | No, skip it |
| **A** | Yes to this one and all the remaining safe ones |
| **Q** | Quit and stop cleaning |

There's a practice question so you can try it. Nothing is deleted during the tour. Press **S** at the start to skip it.

### 2. It scans your Mac

A progress bar shows how far along it is:

```
[##########                    ]  36%  Spotify
```

### 3. It goes through each app, one by one

Each app gets its own screen with what it is, how big it is, and where it lives:

```
[2 of 11]  Google Chrome  -  2.5 GB
  Saved web pages, images and scripts so sites load faster.
  You stay logged in; sites just reload a bit slower once.
  Location: ~/Library/Caches/com.google.Chrome
  Clear it?  [Y]es / [N]o / [A]ll / [Q]uit
```

Small caches from lots of apps are grouped into one line so you're not asked 100 times.

### 4. It may ask for your password

Some junk sits in protected system folders. Kino tells you **exactly what and why** before asking:

```
Some more junk needs your Mac password to remove:

  - System-wide app caches        2.4 GB
  - Time Machine local snapshots  3 found (can be many GB)

Enter your password to clean these too?  [Y]es / [N]o
```

- Press **N** to skip this whole section.
- When asked for the password, **nothing appears as you type**. That's normal. Type it and press Enter.
- The password only unlocks those folders. It is **not saved and not sent anywhere**, and Kino forgets it right after.
- You still get a Yes/No for each item.

### 5. It shows where your space is going

A short list of your biggest folders, then any file over **500 MB** with a number. Type the numbers you want to remove (like `1 3`) and press Enter.

These go to the **Trash**, not straight to deletion. You can get them back until you empty it.

### 6. Trash and results

Kino offers to empty the Trash, then shows your free space before and after.

---

## What it will never touch

- Your photos, documents, music and videos
- Your Photos library
- Your real Time Machine backups
- Anything it hasn't asked you about first

Phone backups (iPhone/iPad) are marked **CAREFUL** and are always asked about one at a time.

---

## Just want to look?

Run this in Terminal. Nothing gets deleted in this mode:

```
bash Kino.command --scan-only
```


---

## Troubleshooting

| Problem | Fix |
|:--|:--|
| Double-click does nothing or says permission denied | Open **Terminal**, type `bash ` (with a space), drag `Kino.command` into the window, press Enter. |
| "Apple cannot check it" message | Right-click the file, choose **Open**, then **Open** again. |
| macOS asks if Terminal can control Finder | Click **OK**. This lets Kino empty the Trash. |
| Password not accepted | Check Caps Lock. Use the password you log in to your Mac with. |
| Not much was freed | Close all apps and run Kino again. |
