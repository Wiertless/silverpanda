#!/usr/bin/bash
# Woken at night by silverpanda-nightly.timer, which runs only while an image
# update is staged (silverpanda-nightly.path). Restarts into the update when
# the battery is above 50% or it's plugged in, nobody is using the laptop and
# no apps are open, then goes back to sleep. Otherwise it goes back to sleep
# and tries again the next night. Nothing is downloaded at night: the base
# image's update timers stage updates while the laptop is awake.
set -uo pipefail

MARKER=/var/lib/silverpanda/nightly-reboot
MIN_BATTERY=50

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
# its chats are saved.
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

apps_open() {
  local user home unit id open
  for user in $(loginctl list-users --no-legend | awk '{print $2}'); do
    home=$(getent passwd "$user" | cut -d: -f6)
    open=()
    while read -r unit; do
      id=$(app_id "$unit")
      [[ -z $id || $id == *PandaAssistant* ]] && continue
      has_launcher "$id" "$home" && open+=("$id")
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

back_to_sleep() {
  local i
  for i in 1 2 3; do
    if ! nobody_using; then
      log "in use: staying awake"
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
  systemctl stop silverpanda-nightly.timer
  back_to_sleep
  exit 0
fi

level=$(battery)
if ! on_mains && ((level <= MIN_BATTERY)); then
  log "battery at ${level}%: trying again tomorrow night"
elif ! nobody_using; then
  log "in use: trying again tomorrow night"
elif apps_open; then
  log "apps are open: trying again tomorrow night"
else
  log "restarting into the staged update (battery ${level}%)"
  mkdir -p "$(dirname "$MARKER")"
  touch "$MARKER"
  systemctl reboot
  exit 0
fi
back_to_sleep
