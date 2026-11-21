#!/usr/bin/env bash
# Auto Brightness, SilverPanda's GNOME Shell extension (files/system/usr/share/
# gnome-shell/extensions): Automatic Screen Brightness that follows the room,
# on an adjustable curve. On by default, next to Assistant's clipboard
# extension (this override comes after panda-assistant.sh's zz1 one).
set -euo pipefail

ext=/usr/share/gnome-shell/extensions/auto-brightness@silverpanda.wiertless.github.io
glib-compile-schemas --strict "$ext/schemas"

cat > /usr/share/glib-2.0/schemas/zz2-silverpanda.gschema.override <<'OVERRIDE'
[org.gnome.shell]
enabled-extensions=['clipboard@assistant.wiertless.github.io', 'auto-brightness@silverpanda.wiertless.github.io']
OVERRIDE
glib-compile-schemas /usr/share/glib-2.0/schemas
