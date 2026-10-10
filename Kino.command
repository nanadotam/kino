#!/bin/bash
# ------------------------------------------------------------------
#  Kino.command  -  friendly disk cleanup for any Mac.
#  Double-click to run. No Python, no installs.
#  - Walks you through a short tutorial first
#  - Shows each app's cache, how big it is, and ASKS before deleting
#  - Finds your biggest files and lets you pick what to Trash
#  Terminal: bash Kino.command [--scan-only] [--no-tour]
# ------------------------------------------------------------------

APP_NAME="Kino"
SCAN_ONLY=0; SKIP_TOUR=0
for a in "$@"; do
  [ "$a" = "--scan-only" ] && SCAN_ONLY=1
  [ "$a" = "--no-tour" ] && SKIP_TOUR=1
done

B=$(printf '\033[1m'); G=$(printf '\033[32m'); Y=$(printf '\033[33m')
R=$(printf '\033[31m'); C=$(printf '\033[36m'); D=$(printf '\033[2m'); N=$(printf '\033[0m')

# ---------- helpers ----------
human() {
  awk -v k="${1:-0}" 'BEGIN{
    if (k>=1048576) printf "%.1f GB", k/1048576;
    else if (k>=1024) printf "%.0f MB", k/1024;
    else printf "%d KB", k }'
}
size_kb() {
  local s
  s=$(du -sk "$1" 2>/dev/null | awk '{print $1}')
  echo "${s:-0}"
}
free_kb() { df -k "$HOME" 2>/dev/null | awk 'NR==2{print $4}'; }
tilde() { echo "${1/#$HOME/~}"; }
ask() { local a; read -r -p "$1" a; echo "$a"; }              # typed answer + Enter
ask_key() {                                                     # single key, no Enter
  local k
  read -r -n 1 -p "$1" k
  echo >&2
  echo "$k" | tr 'A-Z' 'a-z'
}
pause() { read -r -n 1 -s -p "${D}  (press any key to continue)${N}" _; echo; }
clear_dir() { find "$1" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; }

progress() {   # progress <done> <total> <label>
  local cur=$1 tot=$2 label=$3 width=30 pct filled bar
  [ "$tot" -gt 0 ] || return 0
  pct=$((cur*100/tot)); filled=$((cur*width/tot))
  bar=$(printf '%*s' "$filled" '' | tr ' ' '#')
  printf '\r  [%-30s] %3d%%  %s\033[K' "$bar" "$pct" "$label"
}
progress_done() { printf '\r\033[K'; }

pretty_name() {   # bundle-id-ish folder name -> friendly name
  case "$1" in
    com.google.Chrome*|Google) echo "Google Chrome" ;;
    com.apple.Safari*)         echo "Safari" ;;
    company.thebrowser.*)      echo "Arc" ;;
    org.mozilla.firefox|Firefox|org.mozilla.*) echo "Firefox" ;;
    com.brave.*|BraveSoftware) echo "Brave" ;;
    com.spotify.client|Spotify) echo "Spotify" ;;
    com.tinyspeck.slackmacgap*) echo "Slack" ;;
    com.hnc.Discord*|discord)  echo "Discord" ;;
    us.zoom.xos|zoom.us)       echo "Zoom" ;;
    com.microsoft.teams*|com.microsoft.Teams*) echo "Microsoft Teams" ;;
    com.microsoft.*)           echo "Microsoft ${1#com.microsoft.}" ;;
    com.adobe.*|Adobe)         echo "Adobe ${1#com.adobe.}" ;;
    com.apple.*)               echo "Apple: ${1#com.apple.}" ;;
    com.whatsapp.*|WhatsApp)   echo "WhatsApp" ;;
    com.openai.*)              echo "ChatGPT" ;;
    Homebrew)                  echo "Homebrew (developer tools)" ;;
    pip)                       echo "pip (Python installs)" ;;
    com.*|org.*|io.*|net.*|co.*) echo "${1#*.}" ;;
    *)                         echo "$1" ;;
  esac
}
app_note() {      # extra line of context for well-known apps
  case "$1" in
    "Google Chrome"|Safari|Firefox|Brave) echo "Saved web pages, images and scripts so sites load faster. You stay logged in; sites just reload a bit slower once." ;;
    Spotify)   echo "Songs and artwork kept for faster playback. Playlists and account are safe. Offline downloads may need re-downloading." ;;
    Slack|Discord|Zoom|"Microsoft Teams") echo "Images, files and thumbnails from chats and calls. Re-downloaded when you open them again." ;;
    WhatsApp)  echo "Previews and media thumbnails. Your chats are not stored here." ;;
    *)         echo "Temporary files this app saved to run faster. It rebuilds them on its own." ;;
  esac
}

# ---------- welcome + tutorial ----------
FIRST_RUN_TTY=1; [ -t 0 ] || FIRST_RUN_TTY=0
if [ "$SCAN_ONLY" = "0" ] && [ "$FIRST_RUN_TTY" = "0" ]; then
  echo "Please open this file by double-clicking it (or run it in Terminal)."
  exit 1
fi

clear
echo
echo "${B}${C}   _  __  _               ${N}"
echo "${B}${C}  | |/ / (_) _ __   ___    ${N}"
echo "${B}${C}  | ' /  | || '_ \ / _ \   ${N}"
echo "${B}${C}  | . \  | || | | | (_) |  ${N}"
echo "${B}${C}  |_|\_\ |_||_| |_|\___/   ${N}"
echo
echo "  ${B}Welcome to $APP_NAME.${N}"
echo "  I help free up space on your Mac by clearing out junk files"
echo "  that apps leave behind. ${B}Nothing is deleted without your say-so.${N}"
echo

if [ "$SCAN_ONLY" = "0" ] && [ "$SKIP_TOUR" = "0" ]; then
  k=$(ask_key "  Press ${B}Enter${N} for a 1-minute tour, or ${B}S${N} to skip it: ")
  if [ "$k" != "s" ]; then
    clear
    echo "${B}${C}Quick tour  (1 of 3): What is 'cache'?${N}"
    echo
    echo "  Apps save temporary copies of things (pictures, web pages,"
    echo "  songs) so they open faster. Over time these pile up and can"
    echo "  take ${B}many gigabytes${N}."
    echo
    echo "  Clearing them is ${G}safe${N}: apps simply make new ones when needed."
    echo "  Your photos, documents and messages are ${B}not${N} touched."
    echo
    pause

    clear
    echo "${B}${C}Quick tour  (2 of 3): How you answer${N}"
    echo
    echo "  I'll show you one thing at a time and ask what to do."
    echo "  You answer with ${B}one key${N}. No need to press Enter."
    echo
    echo "    ${G}${B}Y${N}  = Yes, clear it"
    echo "    ${R}${B}N${N}  = No, skip it"
    echo "    ${Y}${B}A${N}  = Yes to this and all the rest of the safe ones"
    echo "    ${B}Q${N}  = Quit and stop cleaning"
    echo
    echo "  Capital or small letters both work."
    echo
    pause

    clear
    echo "${B}${C}Quick tour  (3 of 3): Try it${N}"
    echo
    echo "  This is just practice. Nothing will be deleted."
    echo
    tries=0
    while [ $tries -lt 3 ]; do
      k=$(ask_key "  Press ${G}${B}Y${N} to say yes: ")
      if [ "$k" = "y" ]; then
        echo "  ${G}Perfect!${N} That's all there is to it."
        break
      fi
      echo "  Almost. Press the ${B}Y${N} key."
      tries=$((tries+1))
    done
    echo
    echo "  One more thing: some cleaning needs your Mac password."
    echo "  I'll always tell you exactly what and why before asking."
    echo
    pause
  fi
fi

clear
echo "${B}${C}$APP_NAME${N}  -  tip: quit Chrome, Safari, Slack etc. first so more can be cleaned."
echo
FREE_BEFORE=$(free_kb)
echo "Free space right now: ${B}$(human "$FREE_BEFORE")${N}"
echo

# ---------- 1. scan ----------
L="$HOME/Library"
ONAMES=(); OPATHS=(); OWHY=(); ORISKY=()
add_other() { # name path why risky
  [ -d "$2" ] || return 0
  ONAMES+=("$1"); OPATHS+=("$2"); OWHY+=("$3"); ORISKY+=("$4")
}
add_other "System & app logs"          "$L/Logs"                        "Old log files nobody reads." 0
add_other "Mail attachment downloads"  "$L/Containers/com.apple.mail/Data/Library/Mail Downloads" "Copies of attachments you opened. The originals stay in Mail." 0
add_other "Slack (extra cache)"        "$L/Application Support/Slack/Cache" "Slack re-downloads this as needed." 0
add_other "Slack (service-worker cache)" "$L/Application Support/Slack/Service Worker/CacheStorage" "Slack rebuilds this." 0
add_other "Discord (extra cache)"      "$L/Application Support/discord/Cache" "Discord rebuilds this." 0
add_other "Microsoft Teams (extra cache)" "$L/Application Support/Microsoft/Teams/Cache" "Teams rebuilds this." 0
add_other "Zoom (extra data)"          "$L/Application Support/zoom.us/data" "Zoom temp data. Your recordings are NOT here." 0
add_other "npm cache"                  "$HOME/.npm/_cacache"            "Developer package cache. Re-downloads when needed." 0
add_other "Xcode build leftovers"      "$L/Developer/Xcode/DerivedData" "Xcode rebuilds this. Can be many GB." 0
add_other "Xcode iOS device support"   "$L/Developer/Xcode/iOS DeviceSupport" "Re-created when you plug in a device." 0
add_other "iOS Simulator caches"       "$L/Developer/CoreSimulator/Caches" "Rebuilt automatically." 0
add_other "Old iPhone/iPad software updates" "$L/iTunes/iPhone Software Updates" "Downloaded iOS update files you no longer need." 0
add_other "iPhone/iPad backups"        "$L/Application Support/MobileSync/Backup" "${R}CAREFUL:${N} full phone backups. Only delete if you don't need them." 1
add_other "Xcode Archives"             "$L/Developer/Xcode/Archives"    "${R}CAREFUL:${N} past app builds. Only if you're sure." 1

CDIRS=(); for d in "$L/Caches"/*; do [ -d "$d" ] && CDIRS+=("$d"); done
TOTAL_STEPS=$(( ${#CDIRS[@]} + ${#ONAMES[@]} + 1 ))
STEP=0

echo "${B}Scanning your Mac for junk...${N}"
NAMES=(); PATHS=(); WHY=(); RISKY=(); KIND=(); SIZES=()
SMALLP=(); SMALL_KB=0
BIG_THRESHOLD=102400   # apps with >= 100 MB get their own line
CLIST=""
for d in "${CDIRS[@]}"; do
  progress $STEP $TOTAL_STEPS "$(basename "$d")"
  CLIST="$CLIST$(size_kb "$d")"$'\t'"$d"$'\n'
  STEP=$((STEP+1))
done
while IFS=$'\t' read -r kb p; do
  [ -n "$p" ] || continue
  if [ "$kb" -ge "$BIG_THRESHOLD" ]; then
    base=$(basename "$p"); nm=$(pretty_name "$base")
    NAMES+=("$nm"); PATHS+=("$p"); WHY+=("$(app_note "$nm")"); RISKY+=(0); KIND+=(dir); SIZES+=("$kb")
  else
    SMALLP+=("$p"); SMALL_KB=$((SMALL_KB+kb))
  fi
done < <(printf '%s' "$CLIST" | sort -rn)
if [ "$SMALL_KB" -ge 1024 ]; then
  NAMES+=("Lots of small app caches (${#SMALLP[@]} apps)"); PATHS+=(""); KIND+=(small)
  WHY+=("Many apps each keeping a little temporary data. Safe to clear."); RISKY+=(0); SIZES+=("$SMALL_KB")
fi
j=0
while [ $j -lt ${#ONAMES[@]} ]; do
  progress $STEP $TOTAL_STEPS "${ONAMES[$j]}"
  NAMES+=("${ONAMES[$j]}"); PATHS+=("${OPATHS[$j]}"); WHY+=("${OWHY[$j]}"); RISKY+=("${ORISKY[$j]}"); KIND+=(dir)
  SIZES+=("$(size_kb "${OPATHS[$j]}")")
  STEP=$((STEP+1)); j=$((j+1))
done
progress $STEP $TOTAL_STEPS "Trash"
TRASH_KB=$(size_kb "$HOME/.Trash")
progress_done

# ---------- 2. summary ----------
echo "${B}What I found:${N}"
i=0; TOTAL=0
while [ $i -lt ${#NAMES[@]} ]; do
  s=${SIZES[$i]}
  if [ "$s" -ge 1024 ]; then
    printf "  %10s   %s\n" "$(human "$s")" "${NAMES[$i]}"
    [ "${RISKY[$i]}" = "0" ] && TOTAL=$((TOTAL+s))
  fi
  i=$((i+1))
done
printf "  %10s   %s\n" "$(human "$TRASH_KB")" "Trash"
TOTAL=$((TOTAL+TRASH_KB))
echo
echo "Safe to clear (approx): ${G}${B}$(human "$TOTAL")${N}"
echo

if [ "$SCAN_ONLY" = "1" ]; then
  echo "Scan-only mode: nothing was deleted."
  exit 0
fi

# ---------- 3. go through them one by one ----------
echo "${B}Let's go through them one at a time.${N}"
echo "${D}Y = yes   N = no   A = yes to all safe ones   Q = quit${N}"
echo
IDX=(); i=0
while [ $i -lt ${#NAMES[@]} ]; do
  [ "${SIZES[$i]}" -ge 1024 ] && IDX+=("$i")
  i=$((i+1))
done
ALL=0; FREED=0; n=0
for i in "${IDX[@]}"; do
  n=$((n+1))
  echo "${B}${C}[$n of ${#IDX[@]}]${N}  ${B}${NAMES[$i]}${N}  -  ${B}$(human "${SIZES[$i]}")${N}"
  echo "  ${WHY[$i]}"
  [ "${KIND[$i]}" = "dir" ] && echo "  ${D}Location: $(tilde "${PATHS[$i]}")${N}"
  if [ "$ALL" = "1" ] && [ "${RISKY[$i]}" = "0" ]; then
    k=y
  else
    k=$(ask_key "  Clear it?  [Y]es / [N]o / [A]ll / [Q]uit  ")
  fi
  case "$k" in
    y|a)
      [ "$k" = "a" ] && [ "${RISKY[$i]}" = "0" ] && ALL=1
      if [ "$k" = "a" ] && [ "${RISKY[$i]}" = "1" ]; then
        echo "  Skipped (careful items are always asked one by one)."
      else
        if [ "${KIND[$i]}" = "small" ]; then
          for p in "${SMALLP[@]}"; do clear_dir "$p"; done
        else
          clear_dir "${PATHS[$i]}"
        fi
        FREED=$((FREED+${SIZES[$i]})); echo "  ${G}Cleared.${N}"
      fi ;;
    q) echo "  Stopping."; break ;;
    *) echo "  Skipped." ;;
  esac
  echo
done
echo

# ---------- 3b. items that need your Mac password ----------
SNAPS=()
while IFS= read -r line; do
  case "$line" in com.apple.TimeMachine.*) SNAPS+=("$line") ;; esac
done < <(tmutil listlocalsnapshots / 2>/dev/null)

SNAMES=(); SPATHS=(); SSIZES=()
for entry in "System-wide app caches|/Library/Caches" "System logs|/Library/Logs"; do
  nm=${entry%%|*}; pt=${entry#*|}
  [ -d "$pt" ] || continue
  sz=$(size_kb "$pt")
  if [ "$sz" -ge 1024 ]; then SNAMES+=("$nm"); SPATHS+=("$pt"); SSIZES+=("$sz"); fi
done

if [ ${#SNAMES[@]} -gt 0 ] || [ ${#SNAPS[@]} -gt 0 ]; then
  echo "${B}${Y}-------------------------------------------------${N}"
  echo "${B}Some more junk needs your Mac password to remove:${N}"
  echo
  k=0
  while [ $k -lt ${#SNAMES[@]} ]; do
    printf "  - %-28s %s\n" "${SNAMES[$k]}" "$(human "${SSIZES[$k]}")"
    k=$((k+1))
  done
  [ ${#SNAPS[@]} -gt 0 ] && echo "  - Time Machine local snapshots   ${#SNAPS[@]} found (can be many GB)"
  echo
  echo "These live in protected system folders, so macOS needs the"
  echo "password you use to log in to this Mac. It only unlocks these"
  echo "folders; it is not saved or sent anywhere."
  echo "${B}${Y}-------------------------------------------------${N}"
  ans=$(ask_key "Enter your password to clean these too?  [Y]es / [N]o  ")
  if [ "$ans" = "y" ]; then
    if sudo -p "  Mac password (nothing shows as you type): " -v 2>/dev/null; then
      echo
      k=0
      while [ $k -lt ${#SNAMES[@]} ]; do
        echo "${B}${SNAMES[$k]}${N} - $(human "${SSIZES[$k]}")"
        a=$(ask_key "  Clear it?  [Y]es / [N]o  ")
        if [ "$a" = "y" ]; then
          sudo find "${SPATHS[$k]}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
          FREED=$((FREED+${SSIZES[$k]})); echo "  ${G}Cleared.${N}"
        else
          echo "  Skipped."
        fi
        echo
        k=$((k+1))
      done
      if [ ${#SNAPS[@]} -gt 0 ]; then
        echo "${B}Time Machine local snapshots${N} - ${#SNAPS[@]} found"
        echo "  Temporary on-disk copies. Your real Time Machine backups are not touched."
        a=$(ask_key "  Clear them?  [Y]es / [N]o  ")
        if [ "$a" = "y" ]; then
          for snap in "${SNAPS[@]}"; do
            d=${snap#com.apple.TimeMachine.}; d=${d%.local}
            sudo tmutil deletelocalsnapshots "$d" >/dev/null 2>&1
          done
          echo "  ${G}Cleared.${N}"
        else
          echo "  Skipped."
        fi
        echo
      fi
      sudo -k
    else
      echo "  ${R}Password not accepted - skipping these.${N}"
      echo
    fi
  else
    echo "  Skipped."
    echo
  fi
fi

# ---------- 3c. where is the rest of my storage? ----------
echo "${B}Where the rest of your space is going...${N}"
FDIRS=(); for f in "$HOME"/*; do [ -d "$f" ] && FDIRS+=("$f"); done
FOUT=""; n=0
for f in "${FDIRS[@]}"; do
  progress $n ${#FDIRS[@]} "$(basename "$f")"
  FOUT="$FOUT$(size_kb "$f")"$'\t'"$f"$'\n'
  n=$((n+1))
done
progress_done
printf '%s' "$FOUT" | sort -rn | head -8 | while IFS=$'\t' read -r kb p; do
  printf "  %10s   %s\n" "$(human "$kb")" "$(basename "$p")"
done
echo

# ---------- 4. big files ----------
echo "${B}Looking for very large files (over 500 MB)...${N}"
LKB=(); LPATH=()
while IFS=$'\t' read -r kb p; do
  [ -n "$p" ] || continue
  LKB+=("$kb"); LPATH+=("$p")
done < <(find "$HOME" -type f -size +500M \
    -not -path "$HOME/Library/*" -not -path "*/.Trash/*" \
    -not -path "*.photoslibrary/*" -not -path "*/node_modules/*" \
    -print0 2>/dev/null | xargs -0 du -k 2>/dev/null | sort -rn | head -15)

if [ ${#LPATH[@]} -eq 0 ]; then
  echo "  No huge files found."
else
  j=0
  while [ $j -lt ${#LPATH[@]} ]; do
    printf "  %2d)  %9s   %s\n" $((j+1)) "$(human "${LKB[$j]}")" "$(tilde "${LPATH[$j]}")"
    j=$((j+1))
  done
  echo
  echo "Files you pick go to the Trash, so you can still get them back."
  picks=$(ask "Type the numbers to move (e.g. 1 3) then press Enter, or just Enter to skip: ")
  for n in $picks; do
    case "$n" in ''|*[!0-9]*) continue ;; esac
    if [ "$n" -ge 1 ] && [ "$n" -le ${#LPATH[@]} ]; then
      p="${LPATH[$((n-1))]}"
      pe=${p//\\/\\\\}; pe=${pe//\"/\\\"}
      if osascript -e "tell application \"Finder\" to delete POSIX file \"$pe\"" >/dev/null 2>&1; then
        echo "  ${G}Moved to Trash:${N} $(basename "$p")"
        TRASH_KB=$((TRASH_KB+${LKB[$((n-1))]}))
      else
        echo "  ${R}Couldn't move:${N} $p"
      fi
    fi
  done
fi
echo

# ---------- 5. trash ----------
echo "${B}Trash${N} - about $(human "$TRASH_KB")"
ans=$(ask_key "  Empty the Trash now?  [Y]es / [N]o  ")
if [ "$ans" = "y" ]; then
  osascript -e 'tell application "Finder" to empty trash' >/dev/null 2>&1 \
    && echo "  ${G}Trash emptied.${N}" \
    || echo "  ${R}Couldn't empty Trash. Do it manually: Finder > Empty Trash.${N}"
fi
echo

# ---------- 6. summary ----------
sleep 2
FREE_AFTER=$(free_kb)
GAINED=$((FREE_AFTER-FREE_BEFORE))
[ "$GAINED" -lt 0 ] && GAINED=0
echo "${B}${C}=====================================${N}"
echo "  Free before: $(human "$FREE_BEFORE")"
echo "  Free now:    ${G}${B}$(human "$FREE_AFTER")${N}"
echo "  Gained:      ${G}${B}$(human "$GAINED")${N}"
echo "${B}${C}=====================================${N}"
echo
echo "Still need space?"
echo "  - Apple menu > System Settings > General > Storage shows what's big."
echo "  - Move photos/videos to iCloud or an external drive."
echo "  - Uninstall apps you don't use."
echo
echo "Thanks for using $APP_NAME. You can close this window."
read -r -n 1 -s -p "Press any key to close. "
echo
