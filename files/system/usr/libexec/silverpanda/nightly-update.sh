#!/usr/bin/bash
# Woken at night by silverpanda-nightly.timer, which runs only while an image
# update is staged (silverpanda-nightly.path). Restarts into the update when
# the battery is above 20% or it's plugged in, nobody is using the laptop, no
# app reports unsaved work, and every open app is one that brings its own state
# back (those are closed properly first and opened again at the next login, by
# silverpanda-reopen-apps.service); then goes back to sleep. Otherwise it goes
# back to sleep and tries again the next night. Nothing is downloaded at night:
# the base image's update timers stage updates while the laptop is awake.
# --check: say what it would do, without restarting or sleeping.
set -uo pipefail

# shellcheck source=nightly-lib.sh
. /usr/libexec/silverpanda/nightly-lib.sh
nightly_main "$@"
