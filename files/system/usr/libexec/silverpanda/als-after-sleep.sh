#!/usr/bin/env bash
# The Framework 13 (AMD) light sensor hub can come back from sleep reading 0
# lux forever; restarting iio-sensor-proxy doesn't help, reconnecting the I2C
# HID device does. Run after every wake-up (silverpanda-als-after-sleep.service).
set -euo pipefail

dev=i2c-FRMW0005:00
driver=/sys/bus/i2c/drivers/i2c_hid_acpi
[ -e "/sys/bus/i2c/devices/$dev" ] || exit 0

if [ -e "$driver/$dev" ]; then
    echo "$dev" > "$driver/unbind"
    sleep 1
fi
echo "$dev" > "$driver/bind"
# Give the sensor hub time to show up again, then let the proxy find it
# (its clients, like Auto Brightness, claim the light sensor again by themselves).
for _ in $(seq 1 20); do
    compgen -G "/sys/bus/iio/devices/iio:device*/in_illuminance_raw" >/dev/null && break
    sleep 0.25
done
systemctl try-restart iio-sensor-proxy.service
