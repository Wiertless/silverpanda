#!/usr/bin/bash
# Woken at night by silverpanda-nightly.timer: on mains power, install updates
# (the base image's own update services), reboot into a staged image if
# nothing is open, then go back to sleep. On battery it goes straight back to
# sleep. It only suspends or reboots when nobody is using the laptop: the lid
# is closed, or every session is still locked (GNOME locks it when it sleeps),
# so someone who opened it and logged in is never interrupted.
set -uo pipefail

MARKER=/var/lib/silverpanda/nightly-reboot

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

# Apps open in anyone's session: what GNOME and Flatpak start as app-*.scope
# units (autostarted background services are .service units, so they don't
# count; neither does Assistant's window, whose chats are saved).
apps_open() {
  local user units
  for user in $(loginctl list-users --no-legend | awk '{print $2}'); do
    units=$(systemctl --user -M "$user@" list-units --type=scope --state=running \
      --no-legend --plain 'app-*' 2>/dev/null | awk '{print $1}' | grep -v PandaAssistant)
    if [[ -n $units ]]; then
      log "open for $user: $(echo "$units" | tr '\n' ' ')"
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

if ! on_mains; then
  log "on battery: back to sleep without updating"
  back_to_sleep
  exit 0
fi

if nm-online -q -t 90; then
  log "updating"
  # The base image's own services: they skip metered connections and stage the new image.
  timeout 30m systemctl start rpm-ostreed-automatic.service || log "image update failed"
  timeout 10m systemctl start flatpak-system-update.service || log "flatpak update failed"
  for user in $(loginctl list-users --no-legend | awk '{print $2}'); do
    timeout 10m systemctl --user -M "$user@" start flatpak-user-update.service ||
      log "flatpak update for $user failed"
  done
else
  log "no network"
fi

if staged && nobody_using && on_mains && ! apps_open; then
  log "update staged and nothing open: rebooting into it"
  mkdir -p "$(dirname "$MARKER")"
  touch "$MARKER"
  systemctl reboot
  exit 0
fi
back_to_sleep
