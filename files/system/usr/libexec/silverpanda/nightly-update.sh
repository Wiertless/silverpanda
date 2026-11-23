#!/usr/bin/bash
# Woken at night by silverpanda-nightly.timer, which runs only while an image
# update is staged (silverpanda-nightly.path). Restarts into the update when
# the battery is above 20% or it's plugged in, nobody is using the laptop and
# no apps are open, then goes back to sleep. Otherwise it goes back to sleep
# and tries again the next night. Nothing is downloaded at night: the base
# image's update timers stage updates while the laptop is awake.
# --check: say what it would do, without restarting or sleeping.
set -uo pipefail

check=
[[ ${1:-} == --check ]] && check=1

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
# only GNOME's own helpers, don't count.
runs_app() {
  local pid
  while read -r pid; do
    case $(cat "/proc/$pid/comm" 2>/dev/null) in
      "" | gsd-* | gnome-shell | gnome-session* | xdg-* | at-spi* | dbus-*) ;;
      *) return 0 ;;
    esac
  done < <(find "/sys/fs/cgroup$1" -name cgroup.procs -exec cat {} + 2>/dev/null)
  return 1
}

apps_open() {
  local user home unit id open
  for user in $(loginctl list-users --no-legend | awk '{print $2}'); do
    home=$(getent passwd "$user" | cut -d: -f6)
    open=()
    while read -r unit; do
      id=$(app_id "$unit")
      [[ -z $id || $id == *PandaAssistant* || ${id,,} == steam || ${id,,} == com.valvesoftware.steam ]] && continue
      has_launcher "$id" "$home" || continue
      runs_app "$(systemctl --user -M "$user@" show -p ControlGroup --value "$unit" 2>/dev/null)" && open+=("$id")
    done < <(systemctl --user -M "$user@" list-units --state=running --no-legend --plain 'app-*.scope' 'dbus-*@*.service' \
      2>/dev/null | awk '{print $1}')
    if (( ${#open[@]} )); then
      log "open for $user: ${open[*]}"
      return 0
    fi
  done
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
# A dry run reports every check, not only the first that fails.
if [[ $check ]]; then
  [[ $settled ]] && log "check: nothing else running"
  log "check: battery ${level}%, $(on_mains && echo plugged in || echo on battery) (needs >${MIN_BATTERY}% or plugged in)"
  if nobody_using; then log "check: nobody using it"; else log "check: in use (a session is unlocked and the lid is open)"; fi
  apps_open || log "check: no apps open"
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
elif blocker=$(shutdown_blocked); then
  log "asked not to shut down by $blocker: trying again tomorrow night"
elif [[ $check ]]; then
  log "would restart into the staged update (battery ${level}%)"
else
  log "restarting into the staged update (battery ${level}%)"
  mkdir -p "$(dirname "$MARKER")"
  touch "$MARKER"
  # One more try if a job queued in the meantime refuses it.
  if systemctl reboot || { sleep 15 && systemctl reboot; }; then
    exit 0
  fi
  rm -f "$MARKER"
  log "the restart was refused: trying again tomorrow night"
fi
back_to_sleep
