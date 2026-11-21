// Settings: the brightness curve, drawn, with the room's light level live on it.

import Adw from 'gi://Adw';
import Gio from 'gi://Gio';
import Gtk from 'gi://Gtk';
import {ExtensionPreferences, gettext as _} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

import {readCurve, target} from './curve.js';

const POWER_SCHEMA = 'org.gnome.settings-daemon.plugins.power';
const MAX_LUX = 50000; // the graph's right edge
const KEYS = ['dark-level', 'bright-lux', 'curve', 'response'];

const SensorProxy = Gio.DBusProxy.makeProxyWrapper(`
<node>
  <interface name="net.hadess.SensorProxy">
    <method name="ClaimLight"/>
    <method name="ReleaseLight"/>
    <property name="HasAmbientLight" type="b" access="read"/>
    <property name="LightLevel" type="d" access="read"/>
  </interface>
</node>`);

function spinRow(settings, key, title, subtitle, {min, max, step, digits, scale = 1}) {
    const row = new Adw.SpinRow({
        title, subtitle, digits,
        adjustment: new Gtk.Adjustment({lower: min, upper: max, step_increment: step, page_increment: step * 10}),
    });
    const get = () => (key === 'bright-lux' ? settings.get_int(key) : settings.get_double(key)) * scale;
    row.value = get();
    row.connect('notify::value', () => {
        const v = row.value / scale;
        if (key === 'bright-lux')
            settings.set_int(key, Math.round(v));
        else
            settings.set_double(key, v);
    });
    settings.connect(`changed::${key}`, () => {
        if (Math.abs(row.value - get()) > 1e-6)
            row.value = get();
    });
    return row;
}

export default class AutoBrightnessPrefs extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const settings = this.getSettings();
        const power = new Gio.Settings({schema_id: POWER_SCHEMA});
        let lux = null;

        const page = new Adw.PreferencesPage();
        window.add(page);

        // On/off is GNOME's own switch, so it's the same one Settings shows.
        const state = new Adw.PreferencesGroup();
        const toggle = new Adw.SwitchRow({
            title: _('Automatic Screen Brightness'),
            subtitle: _('The same switch as in Settings → Power. The brightness slider still makes it brighter or darker than automatic.'),
        });
        power.bind('ambient-enabled', toggle, 'active', Gio.SettingsBindFlags.DEFAULT);
        state.add(toggle);
        page.add(state);

        const now = new Adw.PreferencesGroup({title: _('Now')});
        const graph = new Gtk.DrawingArea({content_height: 160, margin_top: 6, margin_bottom: 6});
        const reading = new Adw.ActionRow({title: _('Light'), subtitle: _('Waiting for the sensor…')});
        now.add(graph);
        now.add(reading);
        page.add(now);

        const curve = new Adw.PreferencesGroup({title: _('Curve')});
        curve.add(spinRow(settings, 'dark-level', _('Brightness in the dark'),
            _('Percent, at 0 lux'), {min: 0, max: 100, step: 5, digits: 0, scale: 100}));
        curve.add(spinRow(settings, 'bright-lux', _('Full brightness from'),
            _('Lux. A lit room is 50–500; this sensor reads at most about 3300'), {min: 50, max: 50000, step: 100, digits: 0}));
        curve.add(spinRow(settings, 'curve', _('Curve'),
            _('Below 1: brighter in dim light. Above 1: stays dim longer'), {min: 0.3, max: 3, step: 0.1, digits: 1}));
        curve.add(spinRow(settings, 'response', _('Speed'),
            _('Seconds to follow a brighter room; dimming takes three times as long'), {min: 0.2, max: 10, step: 0.1, digits: 1}));
        const reset = new Gtk.Button({label: _('Reset'), valign: Gtk.Align.CENTER});
        reset.connect('clicked', () => KEYS.forEach(k => settings.reset(k)));
        curve.set_header_suffix(reset);
        page.add(curve);

        const update = () => {
            if (lux !== null) {
                const pct = Math.round(target(lux, readCurve(settings)) * 100);
                reading.subtitle = `${Math.round(lux)} lux → ${pct}% ${_('brightness (before the slider)')}`;
            }
            graph.queue_draw();
        };
        settings.connect('changed', update);

        // x: log(lux) from 0 to MAX_LUX; y: brightness 0–100%.
        graph.set_draw_func((area, cr, w, h) => {
            const fg = area.get_color();
            const accent = Adw.StyleManager.get_default().get_accent_color_rgba();
            const pad = 8;
            const x = l => pad + (w - 2 * pad) * Math.log10(1 + l) / Math.log10(1 + MAX_LUX);
            const y = b => h - pad - (h - 2 * pad) * b;
            cr.setSourceRGBA(fg.red, fg.green, fg.blue, 0.15);
            cr.setLineWidth(1);
            for (const l of [10, 100, 1000, 10000]) {
                cr.moveTo(x(l), pad);
                cr.lineTo(x(l), h - pad);
            }
            cr.stroke();
            const c = readCurve(settings);
            cr.setSourceRGBA(accent.red, accent.green, accent.blue, 1);
            cr.setLineWidth(2.5);
            for (let i = 0; i <= 200; i++) {
                const l = 10 ** (Math.log10(1 + MAX_LUX) * i / 200) - 1;
                if (i === 0)
                    cr.moveTo(x(l), y(target(l, c)));
                else
                    cr.lineTo(x(l), y(target(l, c)));
            }
            cr.stroke();
            if (lux !== null) {
                cr.setSourceRGBA(fg.red, fg.green, fg.blue, 0.9);
                cr.arc(x(lux), y(target(lux, c)), 5, 0, 2 * Math.PI);
                cr.fill();
            }
            cr.$dispose();
        });

        // The live reading: hold the sensor while this window is open.
        let proxy = null;
        new SensorProxy(Gio.DBus.system, 'net.hadess.SensorProxy', '/net/hadess/SensorProxy', (p, error) => {
            if (error || !p.HasAmbientLight) {
                reading.subtitle = _('No light sensor found');
                return;
            }
            proxy = p;
            const read = () => {
                lux = proxy.LightLevel;
                update();
            };
            proxy.connect('g-properties-changed', read);
            proxy.ClaimLightRemote(() => read());
        });
        window.connect('close-request', () => {
            proxy?.ReleaseLightRemote(() => {});
            return false;
        });
    }
}
