// Automatic screen brightness that follows the room. GNOME Shell sets the
// screen to (auto target + slider − 0.5); gsd-power computes that target from
// the light sensor but reacts to few changes. While Settings → Power →
// Automatic Screen Brightness is on, this extension computes the target
// instead, on a curve set in its preferences; the brightness slider stays the
// user's "brighter or darker than automatic".

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import GObject from 'gi://GObject';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {QuickMenuToggle, SystemIndicator} from 'resource:///org/gnome/shell/ui/quickSettings.js';
import {Extension, gettext as _} from 'resource:///org/gnome/shell/extensions/extension.js';

import {readCurve, target} from './curve.js';

const POWER_SCHEMA = 'org.gnome.settings-daemon.plugins.power';
const TICK_MS = 50;
// The keyboard comes back on below this share of keyboard-off-lux (no flicker at the edge).
const KEYBOARD_ON_SHARE = 0.7;
// gsd-power's names for keyboard changes the user made: over D-Bus (the Quick
// Settings slider and toggle, the Settings app) and with the Fn key. Others
// (gsd-power restoring or dimming it) don't count as the user's choice.
const USER_SOURCES = ['set property', 'external'];

const SensorProxy = Gio.DBusProxy.makeProxyWrapper(`
<node>
  <interface name="net.hadess.SensorProxy">
    <method name="ClaimLight"/>
    <method name="ReleaseLight"/>
    <property name="HasAmbientLight" type="b" access="read"/>
    <property name="LightLevel" type="d" access="read"/>
  </interface>
</node>`);

// gsd-power's keyboard backlight, as the Quick Settings slider uses it.
const KeyboardProxy = Gio.DBusProxy.makeProxyWrapper(`
<node>
  <interface name="org.gnome.SettingsDaemon.Power.Keyboard">
    <property name="Brightness" type="i" access="readwrite"/>
    <signal name="BrightnessChanged">
      <arg type="i" name="brightness"/>
      <arg type="s" name="source"/>
    </signal>
  </interface>
</node>`);

// In Quick Settings: GNOME's own Automatic Screen Brightness switch, with the
// keyboard backlight and the settings in its menu.
const AutoBrightnessToggle = GObject.registerClass(
class AutoBrightnessToggle extends QuickMenuToggle {
    constructor(ext) {
        super({
            title: _('Auto Brightness'),
            iconName: 'display-brightness-symbolic',
            toggleMode: true,
        });
        ext._power.bind('ambient-enabled', this, 'checked', Gio.SettingsBindFlags.DEFAULT);
        this.menu.setHeader('display-brightness-symbolic', _('Auto Brightness'),
            _('Follows the light in the room'));
        const keyboard = new PopupMenu.PopupSwitchMenuItem(_('Keyboard Backlight'),
            ext._settings.get_boolean('keyboard'));
        keyboard.connect('toggled', (_item, state) => ext._settings.set_boolean('keyboard', state));
        ext._settings.connectObject('changed::keyboard',
            () => keyboard.setToggleState(ext._settings.get_boolean('keyboard')), this);
        this.menu.addMenuItem(keyboard);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this.menu.addAction(_('Settings'), () => ext.openPreferences());
        this.connect('destroy', () => Gio.Settings.unbind(this, 'checked'));
    }
});

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
        // The slider moved (brightness keys too): its bias changes with it.
        manager.connectObject('user-update', () => {
            if (this._current !== null)
                this._applyTarget(this._shellTarget(this._current));
        }, this);
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
        this._kbdDark = null; // unknown until the first reading
        this._kbdSet = null; // what this extension last set
        new KeyboardProxy(Gio.DBus.session, 'org.gnome.SettingsDaemon.Power',
            '/org/gnome/SettingsDaemon/Power', (proxy, error) => {
                if (error)
                    return; // no keyboard backlight control
                this._keyboard = proxy;
                proxy.connectSignal('BrightnessChanged',
                    (_p, _s, [level, source]) => this._keyboardChanged(level, source));
                this._update();
            }, this._cancel, Gio.DBusProxyFlags.NONE);

        this._indicator = new SystemIndicator();
        this._toggle = new AutoBrightnessToggle(this);
        this._indicator.quickSettingsItems.push(this._toggle);
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator);
        this._update();
    }

    disable() {
        if (!this._manager)
            return;
        this._toggle.destroy();
        this._indicator.destroy();
        this._toggle = this._indicator = null;
        this._manager.disconnectObject(this);
        this._stop();
        this._cancel.cancel();
        if (this._proxy) {
            if (this._claimed)
                this._proxy.ReleaseLightRemote(() => {});
            this._proxy.disconnectObject(this);
        }
        this._keyboard = null;
        this._power.disconnectObject(this);
        this._settings.disconnectObject(this);
        delete this._manager.autoBrightnessTarget;
        this._applyTarget(this._gsdTarget ?? -1);
        this._manager = this._applyTarget = this._proxy = this._cancel = null;
        this._settings = this._power = null;
    }

    _sensor() {
        return Boolean(this._proxy?.g_name_owner && this._proxy.HasAmbientLight);
    }

    _on() {
        return this._power.get_boolean('ambient-enabled') && this._sensor();
    }

    _keyboardOn() {
        return Boolean(this._keyboard) && this._settings.get_boolean('keyboard') && this._sensor();
    }

    // Hold the light sensor only while the screen or the keyboard follows the room.
    _claim() {
        const want = this._sensor() && (this._on() || this._keyboardOn());
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
        this._toggle?.set({visible: this._sensor()});
        this._updateKeyboard();
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
            this._applyTarget(this._shellTarget(this._current));
        } else if (!this._tick) {
            this._tick = GLib.timeout_add(GLib.PRIORITY_DEFAULT, TICK_MS, () => this._step());
        }
    }

    // GNOME Shell shows clamp(target + slider − 0.5): with a low automatic level
    // the bottom of the slider all comes out as 0 and the brightness keys seem to
    // do nothing (the top, likewise, in bright light). Pass the target that makes
    // the slider span it all instead: its middle is the automatic level, its ends
    // darkest and brightest, every step visible.
    _shellTarget(auto) {
        const s = this._manager.globalScale?.value ?? 0.5;
        const shown = s < 0.5 ? auto * s / 0.5 : auto + (1 - auto) * (s - 0.5) / 0.5;
        return Math.clamp(shown - s + 0.5, 0, 1);
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
        this._applyTarget(this._shellTarget(this._current));
        if (done)
            this._tick = 0;
        return done ? GLib.SOURCE_REMOVE : GLib.SOURCE_CONTINUE;
    }

    // On in the dark, off in bright light; set only when that flips (or a setting
    // changes), so the Fn key and gsd-power's idle dimming are left alone in between.
    _updateKeyboard() {
        if (!this._keyboardOn() || this._lux === null) {
            this._kbdDark = null;
            return;
        }
        const off = this._settings.get_int('keyboard-off-lux');
        const dark = this._kbdDark === null
            ? this._lux < off
            : this._kbdDark ? this._lux < off : this._lux < off * KEYBOARD_ON_SHARE;
        const level = dark ? this._settings.get_int('keyboard-level') : 0;
        if (dark === this._kbdDark && level === this._kbdSet)
            return;
        this._kbdDark = dark;
        this._kbdSet = level;
        this._keyboard.Brightness = level;
    }

    _keyboardChanged(level, source) {
        if (this._kbdDark === null || level === this._kbdSet)
            return;
        if (USER_SOURCES.includes(source)) {
            // The user's choice: left alone until the room flips; in the dark it's the new level.
            this._kbdSet = level;
            if (this._kbdDark && level > 0)
                this._settings.set_int('keyboard-level', level);
        } else if (level > 0) {
            // gsd-power put back its own level (at login, after idle): ours again.
            // (It turning the light off on idle is left alone.)
            this._keyboard.Brightness = this._kbdSet;
        }
    }

    _stop() {
        if (this._tick)
            GLib.source_remove(this._tick);
        this._tick = 0;
    }
}
