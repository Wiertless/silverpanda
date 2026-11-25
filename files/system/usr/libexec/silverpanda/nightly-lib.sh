# shellcheck shell=bash
# What silverpanda's nightly update decides with, shared by the night job
# (nightly-update.sh) and the silverpanda-nightly command, so both see the
# same thing. Sourced, not run.

# Set by nightly_main: a dry run (--check) says what it would do, without
# restarting, closing anything or sleeping.
check=
MARKER=/var/lib/silverpanda/nightly-reboot
MIN_BATTERY=20

log() { echo "silverpanda-nightly: $*"; }

on_mains() {
  local s
  for s in /sys/class/power_supply/*; do
    if [[ $(cat "$s/type" 2>/dev/null) == Mains && $(cat "$s/online" 2>/dev/null) == 1 ]]; then
      return 0
    fi
  done
  return 1
}

# The lowest battery level, or 100 with no battery.
battery() {
  local s level=100 c
  for s in /sys/class/power_supply/*; do
    if [[ $(cat "$s/type" 2>/dev/null) == Battery ]]; then
      c=$(cat "$s/capacity" 2>/dev/null || echo 0)
      ((c < level)) && level=$c
    fi
  done
  echo "$level"
}

lid_closed() {
  grep -qs closed /proc/acpi/button/lid/*/state
}

# Users' sessions (not the login screen's).
user_sessions() {
  local s
  for s in $(loginctl list-sessions --no-legend | awk '{print $1}'); do
    if [[ $(loginctl show-session "$s" -p Class --value) == user ]]; then
      echo "$s"
    fi
  done
}

# Lid closed, or every session still locked (GNOME locks it when it sleeps).
nobody_using() {
  local s
  lid_closed && return 0
  for s in $(user_sessions); do
    if [[ $(loginctl show-session "$s" -p LockedHint --value) != yes ]]; then
      return 1
    fi
  done
  return 0
}

# Apps open in anyone's session. GNOME runs an app as app-gnome-ID-PID.scope,
# or, when it starts over D-Bus (Ptyxis, Nautilus…), as dbus-:1.N-ID@M.service.
# Only units whose ID has a visible launcher count: background helpers
# (autostart-only like DiskUtilityNotify, NoDisplay like CalendarServer,
# D-Bus services with no launcher) don't, and Assistant's window doesn't, as
# its chats are saved, and Steam doesn't (the owner doesn't mind it closing).
app_id() {
  local u=${1//\\x2d/-}
  case $u in
    app-gnome-*.scope | app-flatpak-*.scope) u=${u#app-gnome-}; u=${u#app-flatpak-}; u=${u%.scope}; echo "${u%-[0-9]*}" ;;
    dbus-*@*.service) u=${u#dbus-:*-}; echo "${u%@*}" ;;
  esac
}

has_launcher() {
  local id=$1 home=$2 d f
  for d in /usr/share/applications /usr/local/share/applications /var/lib/flatpak/exports/share/applications \
    "$home/.local/share/applications" "$home/.local/share/flatpak/exports/share/applications"; do
    f=$d/$id.desktop
    if [[ -f $f ]]; then
      grep -qiE '^(NoDisplay|Hidden)=true' "$f" && return 1
      return 0
    fi
  done
  return 1
}

# Whether a unit's cgroup still runs a real program. A unit can outlive its app:
# a media key starts G4Music as app-gnome-…g4music-0.scope with gsd-media-keys
# itself inside, which stays after G4Music quits. Empty units, and ones holding
# only GNOME's own helpers, don't count, and neither does a unit that's gone
# (systemd then gives no cgroup: without this check, the whole tree is searched).
runs_app() {
  local pid
  [[ -n $1 && -d /sys/fs/cgroup$1 ]] || return 1
  while read -r pid; do
    case $(cat "/proc/$pid/comm" 2>/dev/null) in
      "" | gsd-* | gnome-shell | gnome-session* | xdg-* | at-spi* | dbus-*) ;;
      *) return 0 ;;
    esac
  done < <(find "/sys/fs/cgroup$1" -name cgroup.procs -exec cat {} + 2>/dev/null)
  return 1
}

# Apps that bring their own state back when closed properly and opened again:
# browsers reopen their tabs; these editors keep unsaved text (Zed in its
# database, VS Code and Sublime Text as hot-exit backups, Text Editor as
# drafts; Obsidian saves as you type); the rest hold nothing a restart loses.
# Ptyxis restores its tabs but not what runs in them (see terminal_idle).
RESTORABLE=(
  helium firefox org.mozilla.firefox chromium-browser org.chromium.Chromium google-chrome com.google.Chrome
  brave-browser com.brave.Browser
  dev.zed.Zed md.obsidian.Obsidian org.gnome.TextEditor code com.visualstudio.code codium com.vscodium.codium
  sublime_text com.sublimetext.three
  org.gnome.Nautilus org.gnome.Settings org.gnome.Calendar org.gnome.Calculator org.gnome.clocks org.gnome.Weather
  org.gnome.Loupe org.gnome.Papers org.gnome.Evince org.gnome.Characters com.github.neithern.g4music
  org.gnome.Ptyxis
)

# Each user's own choices, in ~/.config/silverpanda/restorable-apps
# (silverpanda-nightly allow/block/reset writes it): an app ID on a line lets
# the update close and reopen it; "-ID" never closes it, so the update waits
# while it's open; "#" starts a comment. The last line about an app wins.
CHOICES=.config/silverpanda/restorable-apps

# allow, block, or nothing (the built-in list decides).
choice() {
  local home=$1 id=$2 line c=
  [[ -r $home/$CHOICES ]] || return 0
  while IFS= read -r line; do
    line=${line%%#*}
    line=${line//[[:space:]]/}
    [[ $line == "$id" ]] && c=allow
    [[ $line == "-$id" ]] && c=block
  done < "$home/$CHOICES"
  echo "$c"
}

builtin_restorable() {
  local r
  for r in "${RESTORABLE[@]}"; do [[ $1 == "$r" ]] && return 0; done
  return 1
}

restorable() {
  local home=$1 id=$2
  case $(choice "$home" "$id") in
    allow) return 0 ;;
    block) return 1 ;;
  esac
  builtin_restorable "$id"
}

# The desktop file of a visible app, by ID.
launcher() {
  local id=$1 home=$2 d
  for d in /usr/share/applications /usr/local/share/applications /var/lib/flatpak/exports/share/applications \
    "$home/.local/share/applications" "$home/.local/share/flatpak/exports/share/applications"; do
    [[ -f $d/$id.desktop ]] && { echo "$d/$id.desktop"; return 0; }
  done
  return 1
}

# An app's name as its launcher shows it, or its ID.
app_name() {
  local f n
  f=$(launcher "$1" "$2") && n=$(grep -m1 '^Name=' "$f" | cut -d= -f2-)
  echo "${n:-$1}"
}

# Every terminal tab is only its shell. A tab runs as ptyxis-spawn-*.scope;
# conmon is a toolbox container's monitor, which outlives the tab that
# entered it. Anything else (a build, an editor, an SSH session) is work a
# restart would cut off.
terminal_idle() {
  local user=$1 unit cg pid
  while read -r unit; do
    cg=$(systemctl --user -M "$user@" show -p ControlGroup --value "$unit" 2>/dev/null)
    [[ -n $cg && -d /sys/fs/cgroup$cg ]] || continue
    while read -r pid; do
      case $(cat "/proc/$pid/comm" 2>/dev/null) in
        "" | bash | fish | zsh | sh | conmon) ;;
        *) return 1 ;;
      esac
    done < <(find "/sys/fs/cgroup$cg" -name cgroup.procs -exec cat {} + 2>/dev/null)
  done < <(systemctl --user -M "$user@" list-units --state=running --no-legend --plain 'ptyxis-spawn-*.scope' \
    2>/dev/null | awk '{print $1}')
  return 0
}

# Sorts the open apps: CLOSE ("user unit id") can be closed and opened again,
# BLOCKING ("user:id") can't.
CLOSE=()
BLOCKING=()
classify() {
  local user home unit id
  CLOSE=()
  BLOCKING=()
  for user in $(loginctl list-users --no-legend | awk '{print $2}'); do
    home=$(getent passwd "$user" | cut -d: -f6)
    while read -r unit; do
      id=$(app_id "$unit")
      [[ -z $id || $id == *PandaAssistant* || ${id,,} == steam || ${id,,} == com.valvesoftware.steam ]] && continue
      has_launcher "$id" "$home" || continue
      runs_app "$(systemctl --user -M "$user@" show -p ControlGroup --value "$unit" 2>/dev/null)" || continue
      if restorable "$home" "$id" && { [[ $id != org.gnome.Ptyxis ]] || terminal_idle "$user"; }; then
        CLOSE+=("$user $unit $id")
      else
        BLOCKING+=("$user:$id")
      fi
    done < <(systemctl --user -M "$user@" list-units --state=running --no-legend --plain 'app-*.scope' 'dbus-*@*.service' \
      2>/dev/null | awk '{print $1}')
  done
}

# Open apps that can't be closed and opened again without losing something.
apps_open() {
  if (( ${#BLOCKING[@]} )); then
    log "open: ${BLOCKING[*]}"
    return 0
  fi
  return 1
}

staged() {
  rpm-ostree status --json 2>/dev/null |
    python3 -c 'import json,sys; sys.exit(0 if any(d.get("staged") for d in json.load(sys.stdin)["deployments"]) else 1)'
}

# What's still running: systemd jobs other than this run (whatever started at
# the wake: the light sensor's reconnect, the Flatpak and rpm-ostree update
# timers catching up, fstrim; a queued one makes systemd refuse the reboot, and
# a restart would cut the others off), and an rpm-ostree transaction.
busy() {
  systemctl list-jobs --no-legend --plain 2>/dev/null | awk '$2 != "silverpanda-nightly.service" {print $2}'
  rpm-ostree status --json 2>/dev/null |
    python3 -c 'import json,sys; t=json.load(sys.stdin).get("transaction"); t and print("rpm-ostree")'
}

# Wait up to 15 minutes for that to finish.
settle() {
  local i b
  for i in $(seq 90); do
    b=$(busy)
    [[ -z $b ]] && return 0
    ((i == 1)) && log "waiting for: $(echo $b)"
    [[ $check ]] && return 1
    sleep 10
  done
  log "still running: $(echo $b)"
  return 1
}

# Apps that asked not to be shut down (a download, a backup, an install).
shutdown_blocked() {
  busctl call --json=short org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager ListInhibitors 2>/dev/null |
    python3 -c '
import json, sys
found = [f"{w[1]} ({w[2]})" for w in json.load(sys.stdin)["data"][0] if "shutdown" in w[0].split(":") and w[3] == "block"]
print(", ".join(found)); sys.exit(0 if found else 1)'
}

# Runs a command as a user, on their session bus: through runuser at night
# (root), directly when silverpanda-nightly runs as that user.
as_user() {
  local user=$1
  shift
  if ((EUID == 0)); then
    runuser -u "$user" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$user")/bus" "$@"
  elif [[ $user == "$(id -un)" ]]; then
    "$@"
  else
    return 1
  fi
}

# Unsaved work an app told GNOME about: what makes Log Out list "unsaved
# documents" (an inhibitor with the logout flag, 1). Apps that don't tell
# GNOME either keep their own state (RESTORABLE) or are in BLOCKING. A user
# with apps to close whose session can't be asked counts as unsaved.
unsaved_work() {
  local user paths p flags found=()
  for user in $(printf '%s\n' "${CLOSE[@]}" | awk '{print $1}' | sort -u); do
    if ! paths=$(as_user "$user" busctl --user --json=short call org.gnome.SessionManager /org/gnome/SessionManager \
      org.gnome.SessionManager GetInhibitors 2>/dev/null |
      python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["data"][0]))'); then
      found+=("$user's session (it couldn't be asked)")
      continue
    fi
    for p in $paths; do
      flags=$(as_user "$user" busctl --user call org.gnome.SessionManager "$p" org.gnome.SessionManager.Inhibitor \
        GetFlags 2>/dev/null | awk '{print $2}')
      (( ${flags:-0} & 1 )) || continue
      found+=("$(as_user "$user" busctl --user call org.gnome.SessionManager "$p" org.gnome.SessionManager.Inhibitor \
        GetAppId 2>/dev/null | cut -d'"' -f2): $(as_user "$user" busctl --user call org.gnome.SessionManager "$p" \
        org.gnome.SessionManager.Inhibitor GetReason 2>/dev/null | cut -d'"' -f2)")
    done
  done
  (( ${#found[@]} )) || return 1
  printf '%s\n' "${found[@]}" | paste -sd, -
}

# Whether a unit still runs its app (see runs_app).
still_running() {
  runs_app "$(systemctl --user -M "$1@" show -p ControlGroup --value "$2" 2>/dev/null)"
}

wait_closed() {
  local i
  for i in $(seq "$3"); do
    still_running "$1" "$2" || return 0
    sleep 1
  done
  return 1
}

# Closes the CLOSE apps properly and writes each user's list for
# silverpanda-reopen-apps.service. A GApplication (Nautilus, Ptyxis, Text
# Editor…) quits through its quit action; anything else, or one that didn't,
# gets what a logout sends: SIGTERM to every process in its unit (browsers
# save their session on it, but need some seconds; a Flatpak app's own
# processes get it, not only its sandbox). What's left after 30 s is stopped
# with its unit (then it fails: that app may have lost something).
# Zed's database is copied first, as a fallback for its unsaved tabs.
close_apps() {
  local e user unit id home d forced=0
  for user in $(printf '%s\n' "${CLOSE[@]}" | awk '{print $1}' | sort -u); do
    home=$(getent passwd "$user" | cut -d: -f6)
    printf '%s\n' "${CLOSE[@]}" | awk -v u="$user" '$1 == u {print $3}' | awk '!seen[$0]++' |
      as_user "$user" sh -c 'mkdir -p "$1" && cat > "$1/reopen"' _ "$home/.local/state/silverpanda"
  done
  for e in "${CLOSE[@]}"; do
    read -r user unit id <<<"$e"
    home=$(getent passwd "$user" | cut -d: -f6)
    if [[ $id == dev.zed.Zed ]]; then
      for d in "$home/.local/share/zed/db" "$home/.var/app/dev.zed.Zed/data/zed/db"; do
        [[ -d $d ]] && as_user "$user" sh -c 'rm -rf "$1.before-nightly" && cp -a "$1" "$1.before-nightly"' _ "$d"
      done
    fi
    log "closing $id"
    as_user "$user" timeout 5 gapplication action "$id" quit >/dev/null 2>&1 && wait_closed "$user" "$unit" 10 && continue
    systemctl --user -M "$user@" kill --signal=TERM "$unit" 2>/dev/null
    wait_closed "$user" "$unit" 30 && continue
    log "$id didn't close in 30 s: stopping it"
    systemctl --user -M "$user@" stop "$unit" 2>/dev/null
    forced=1
  done
  ((forced == 0))
}

# If the restart doesn't happen after all: open the closed apps again now.
reopen_now() {
  local user
  for user in $(printf '%s\n' "${CLOSE[@]}" | awk '{print $1}' | sort -u); do
    systemctl --user -M "$user@" start --no-block silverpanda-reopen-apps.service
  done
}

back_to_sleep() {
  local i
  for i in 1 2 3; do
    if ! nobody_using; then
      log "in use: staying awake"
      return
    fi
    if [[ $check ]]; then
      log "would go back to sleep"
      return
    fi
    # It was asleep before the timer woke it, so whatever held the system
    # awake then doesn't count now.
    systemctl suspend --check-inhibitors=no && return
    log "suspend failed (try $i); retrying in a minute"
    sleep 60
  done
}

# The night job. --check: a dry run; --after-reboot: the first boot after it.
nightly_main() {
  local settled level u b blocker
  check=
  [[ ${1:-} == --check ]] && check=1
  if [[ ${1:-} == --after-reboot ]]; then
    rm -f "$MARKER"
    # Give the login screen a moment; then sleep unless someone logged in or opened the lid.
    sleep 120
    if [[ -n $(user_sessions) ]]; then
      log "someone logged in after the update: staying awake"
      exit 0
    fi
    back_to_sleep
    exit 0
  fi

  if ! staged; then
    log "nothing staged any more"
    [[ $check ]] || systemctl stop silverpanda-nightly.timer
    back_to_sleep
    exit 0
  fi

  # Checked after the wait, which can take a while.
  settled=1
  settle || settled=
  level=$(battery)
  classify
  # A dry run reports every check, not only the first that fails.
  if [[ $check ]]; then
    [[ $settled ]] && log "check: nothing else running"
    log "check: battery ${level}%, $(on_mains && echo plugged in || echo on battery) (needs >${MIN_BATTERY}% or plugged in)"
    if nobody_using; then log "check: nobody using it"; else log "check: in use (a session is unlocked and the lid is open)"; fi
    apps_open || log "check: no apps open that it can't close and open again"
    if (( ${#CLOSE[@]} )); then
      log "check: would close and open again at the next login: $(printf '%s\n' "${CLOSE[@]}" | awk '{print $3}' | paste -sd' ' -)"
    fi
    if u=$(unsaved_work); then log "check: unsaved work: $u"; else log "check: no unsaved work reported"; fi
    if b=$(shutdown_blocked); then log "check: asked not to shut down by $b"; else log "check: no shutdown locks"; fi
    log "verdict:"
  fi
  if [[ ! $settled ]]; then
    log "still busy: trying again tomorrow night"
  elif ! on_mains && ((level <= MIN_BATTERY)); then
    log "battery at ${level}%: trying again tomorrow night"
  elif ! nobody_using; then
    log "in use: trying again tomorrow night"
  elif apps_open; then
    log "apps are open: trying again tomorrow night"
  elif u=$(unsaved_work); then
    log "unsaved work ($u): trying again tomorrow night"
  elif blocker=$(shutdown_blocked); then
    log "asked not to shut down by $blocker: trying again tomorrow night"
  elif [[ $check ]]; then
    log "would restart into the staged update (battery ${level}%)"
  else
    log "restarting into the staged update (battery ${level}%)"
    mkdir -p "$(dirname "$MARKER")"
    touch "$MARKER"
    close_apps
    # One more try if a job queued in the meantime refuses it.
    if systemctl reboot || { sleep 15 && systemctl reboot; }; then
      exit 0
    fi
    rm -f "$MARKER"
    reopen_now
    log "the restart was refused: trying again tomorrow night"
  fi
  back_to_sleep
}
