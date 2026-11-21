// Automatic screen brightness that follows the room. GNOME Shell sets the
// screen to (auto target + slider − 0.5); gsd-power computes that target from
// the light sensor but reacts to few changes. While Settings → Power →
// Automatic Screen Brightness is on, this extension computes the target
// instead, on a curve set in its preferences; the brightness slider stays the
// user's "brighter or darker than automatic".

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {readCurve, target} from './curve.js';

const POWER_SCHEMA = 'org.gnome.settings-daemon.plugins.power';
const TICK_MS = 50;

const SensorProxy = Gio.DBusProxy.makeProxyWrapper(`
<node>
  <interface name="net.hadess.SensorProxy">
    <method name="ClaimLight"/>
    <method name="ReleaseLight"/>
    <property name="HasAmbientLight" type="b" access="read"/>
    <property name="LightLevel" type="d" access="read"/>
  </interface>
</node>`);

export default class AutoBrightness extends Extension {
    enable() {
        const manager = Main.brightnessManager;
        const setter = manager &&
            Object.getOwnPropertyDescriptor(Object.getPrototypeOf(manager), 'autoBrightnessTarget')?.set;
        if (!setter) {
            console.warn(`${this.uuid}: this GNOME Shell has no auto brightness target; doing nothing`);
            return;
        }
        this._manager = manager;
        this._applyTarget = v => setter.call(manager, v);
        // What gsd-power sends over D-Bus is kept (and put back on disable), not applied.
        this._gsdTarget = manager.autoBrightnessTarget;
        Object.defineProperty(manager, 'autoBrightnessTarget', {
            configurable: true,
            get: () => manager._abTarget,
            set: v => {
                this._gsdTarget = v;
            },
        });

        this._lux = null;
        this._current = null;
        this._goal = null;
        this._claimed = false;
        this._settings = this.getSettings();
        this._power = new Gio.Settings({schema_id: POWER_SCHEMA});
        this._power.connectObject('changed::ambient-enabled', () => this._update(), this);
        this._settings.connectObject('changed', () => this._update(), this);

        this._cancel = new Gio.Cancellable();
        new SensorProxy(Gio.DBus.system, 'net.hadess.SensorProxy', '/net/hadess/SensorProxy',
            (proxy, error) => {
                if (error) {
                    if (!error.matches(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                        console.warn(`${this.uuid}: no sensor proxy: ${error.message}`);
                    return;
                }
                this._proxy = proxy;
                proxy.connectObject(
                    'g-properties-changed', () => this._read(),
                    // iio-sensor-proxy restarted: its claims are gone.
                    'notify::g-name-owner', () => {
                        this._claimed = false;
                        this._update();
                    }, this);
                this._read();
            }, this._cancel, Gio.DBusProxyFlags.NONE);
        this._update();
    }

    disable() {
        if (!this._manager)
            return;
        this._stop();
        this._cancel.cancel();
        if (this._proxy) {
            if (this._claimed)
                this._proxy.ReleaseLightRemote(() => {});
            this._proxy.disconnectObject(this);
        }
        this._power.disconnectObject(this);
        this._settings.disconnectObject(this);
        delete this._manager.autoBrightnessTarget;
        this._applyTarget(this._gsdTarget ?? -1);
        this._manager = this._applyTarget = this._proxy = this._cancel = null;
        this._settings = this._power = null;
    }

    _on() {
        return this._power.get_boolean('ambient-enabled') &&
            this._proxy?.g_name_owner && this._proxy.HasAmbientLight;
    }

    // Hold the light sensor only while automatic brightness is on.
    _claim() {
        const want = Boolean(this._on());
        if (!this._proxy || want === this._claimed)
            return;
        this._claimed = want;
        if (want)
            this._proxy.ClaimLightRemote(() => {});
        else
            this._proxy.ReleaseLightRemote(() => {});
    }

    _read() {
        const lux = this._proxy?.LightLevel;
        this._lux = typeof lux === 'number' ? lux : null;
        this._update();
    }

    _update() {
        if (!this._manager)
            return;
        this._claim();
        if (!this._on() || this._lux === null) {
            // Off: whatever gsd-power says (-1, "no auto brightness", when it's off too).
            this._stop();
            this._current = null;
            this._applyTarget(this._gsdTarget ?? -1);
            return;
        }
        this._goal = target(this._lux, readCurve(this._settings));
        if (this._current === null) {
            this._current = this._goal;
            this._applyTarget(this._current);
        } else if (!this._tick) {
            this._tick = GLib.timeout_add(GLib.PRIORITY_DEFAULT, TICK_MS, () => this._step());
        }
    }

    // Glide toward the goal: about 95% of the way in `response` seconds when
    // brightening, three times slower when dimming.
    _step() {
        const response = this._settings.get_double('response');
        const tau = (this._goal > this._current ? response : 3 * response) / 3;
        this._current += (this._goal - this._current) * (1 - Math.exp(-TICK_MS / 1000 / tau));
        const done = Math.abs(this._goal - this._current) < 0.002;
        if (done)
            this._current = this._goal;
        this._applyTarget(this._current);
        if (done)
            this._tick = 0;
        return done ? GLib.SOURCE_REMOVE : GLib.SOURCE_CONTINUE;
    }

    _stop() {
        if (this._tick)
            GLib.source_remove(this._tick);
        this._tick = 0;
    }
}
