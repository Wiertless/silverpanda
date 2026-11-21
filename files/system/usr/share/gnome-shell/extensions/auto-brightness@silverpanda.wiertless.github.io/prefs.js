// Settings: the brightness curve as points to drag (like an equalizer), with
// the room's light level live on it.

import Adw from 'gi://Adw';
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import Gtk from 'gi://Gtk';
import Pango from 'gi://Pango';
import PangoCairo from 'gi://PangoCairo';
import {ExtensionPreferences, gettext as _} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

import {BANDS, keepRising, position, readCurve, target} from './curve.js';

const POWER_SCHEMA = 'org.gnome.settings-daemon.plugins.power';
const GRAPH_MAX_LUX = 10000; // the graph's right edge
const KEYBOARD_KEYS = ['keyboard-level', 'keyboard-off-lux'];
const KEYBOARD_ON_SHARE = 0.7; // as in extension.js
const POINT_RADIUS = 7;
const GRAB_DISTANCE = 22; // px from a point that still picks it up
const WRITE_EVERY_MS = 80; // while dragging, so the real screen follows

const SensorProxy = Gio.DBusProxy.makeProxyWrapper(`
<node>
  <interface name="net.hadess.SensorProxy">
    <method name="ClaimLight"/>
    <method name="ReleaseLight"/>
    <property name="HasAmbientLight" type="b" access="read"/>
    <property name="LightLevel" type="d" access="read"/>
  </interface>
</node>`);

/** What a light level is like, in words. */
function describeLux(lux) {
    if (lux < 5)
        return _('dark');
    if (lux < 50)
        return _('dim, like a lamp across the room');
    if (lux < 300)
        return _('a lit room');
    if (lux < 1000)
        return _('bright, like a lamp right by the laptop');
    if (lux < 3000)
        return _('daylight');
    return _('direct light');
}

function spinRow(settings, key, title, subtitle, {min, max, step, digits}) {
    const row = new Adw.SpinRow({
        title, subtitle, digits,
        adjustment: new Gtk.Adjustment({lower: min, upper: max, step_increment: step, page_increment: step * 10}),
    });
    const isInt = settings.settings_schema.get_key(key).get_value_type().dup_string() === 'i';
    const get = () => isInt ? settings.get_int(key) : settings.get_double(key);
    row.value = get();
    row.connect('notify::value', () => {
        if (isInt)
            settings.set_int(key, Math.round(row.value));
        else
            settings.set_double(key, row.value);
    });
    settings.connect(`changed::${key}`, () => {
        if (Math.abs(row.value - get()) > 1e-6)
            row.value = get();
    });
    return row;
}

function resetButton(onClick) {
    const button = new Gtk.Button({
        icon_name: 'edit-undo-symbolic',
        tooltip_text: _('Back to the defaults'),
        valign: Gtk.Align.CENTER,
        css_classes: ['flat'],
    });
    button.connect('clicked', onClick);
    return button;
}

/** The curve to drag: points at fixed light levels, the room now as a dot. */
function curveEditor(settings, getLux) {
    const area = new Gtk.DrawingArea({
        content_height: 240, hexpand: true,
        margin_top: 12, margin_bottom: 6, margin_start: 6, margin_end: 12,
    });
    let points = readCurve(settings);
    let dragging = -1, hover = -1, lastWrite = 0, startY = 0;
    const box = {left: 40, right: 10, top: 12, bottom: 24};

    const geometry = () => {
        const w = area.get_width(), h = area.get_height();
        const x = l => box.left + (w - box.left - box.right) * position(Math.min(l, GRAPH_MAX_LUX)) /
            position(GRAPH_MAX_LUX);
        const y = b => h - box.bottom - (h - box.top - box.bottom) * b;
        const valueAt = py => Math.min(1, Math.max(0, (h - box.bottom - py) / (h - box.top - box.bottom)));
        return {w, h, x, y, valueAt};
    };
    const nearest = (px, py) => {
        const {x, y} = geometry();
        let best = -1, bestD = GRAB_DISTANCE;
        BANDS.forEach((l, i) => {
            const d = Math.hypot(px - x(l), py - y(points[i]));
            if (d < bestD) {
                best = i;
                bestD = d;
            }
        });
        // Anywhere in a point's column picks it up too, like an equalizer slider.
        if (best < 0) {
            BANDS.forEach((l, i) => {
                if (Math.abs(px - x(l)) < GRAB_DISTANCE / 2)
                    best = i;
            });
        }
        return best;
    };
    const write = () => {
        settings.set_value('points', new GLib.Variant('ad', points));
        lastWrite = GLib.get_monotonic_time() / 1000;
    };

    const drag = new Gtk.GestureDrag();
    drag.connect('drag-begin', (_g, px, py) => {
        dragging = nearest(px, py);
        startY = py;
        if (dragging >= 0) {
            points = keepRising(points.with(dragging, geometry().valueAt(py)), dragging);
            area.set_cursor_from_name('grabbing');
            area.queue_draw();
        }
    });
    drag.connect('drag-update', (_g, _dx, dy) => {
        if (dragging < 0)
            return;
        points = keepRising(points.with(dragging, geometry().valueAt(startY + dy)), dragging);
        area.queue_draw();
        if (GLib.get_monotonic_time() / 1000 - lastWrite > WRITE_EVERY_MS)
            write();
    });
    drag.connect('drag-end', () => {
        if (dragging >= 0)
            write();
        dragging = -1;
        area.set_cursor_from_name(hover >= 0 ? 'grab' : null);
        area.queue_draw();
    });
    area.add_controller(drag);

    const motion = new Gtk.EventControllerMotion();
    motion.connect('motion', (_m, px, py) => {
        const h = nearest(px, py);
        if (h !== hover && dragging < 0) {
            hover = h;
            area.set_cursor_from_name(h >= 0 ? 'grab' : null);
            area.queue_draw();
        }
    });
    motion.connect('leave', () => {
        hover = -1;
        area.queue_draw();
    });
    area.add_controller(motion);

    settings.connect('changed::points', () => {
        if (dragging < 0)
            points = readCurve(settings);
        area.queue_draw();
    });
    settings.connect('changed::keyboard', () => area.queue_draw());
    settings.connect('changed::keyboard-off-lux', () => area.queue_draw());

    area.set_draw_func((_a, cr) => {
        const {w, h, x, y} = geometry();
        const fg = area.get_color();
        const style = Adw.StyleManager.get_default();
        const accent = style.get_accent_color_rgba();
        const ink = a => cr.setSourceRGBA(fg.red, fg.green, fg.blue, a);
        // The interface font at caption size, as the widget itself would draw it.
        const font = area.get_pango_context().get_font_description().copy();
        font.set_size(Math.round(font.get_size() * 0.75));
        const text = (s, tx, ty, align = 0.5, bold = false) => {
            const layout = area.create_pango_layout(s);
            const f = font.copy();
            if (bold)
                f.set_weight(Pango.Weight.BOLD);
            layout.set_font_description(f);
            const [, logical] = layout.get_pixel_extents();
            cr.moveTo(tx - logical.width * align, ty - logical.height / 2);
            PangoCairo.show_layout(cr, layout);
            cr.newPath(); // or the next shape starts with a line from here
        };

        // Room on the left for the widest percent label.
        const probe = area.create_pango_layout('100%');
        probe.set_font_description(font);
        box.left = probe.get_pixel_extents()[1].width + 14;

        // Grid and labels.
        cr.setLineWidth(1);
        ink(0.1);
        for (const l of [1, 10, 100, 1000, 10000]) {
            cr.moveTo(x(l), box.top);
            cr.lineTo(x(l), h - box.bottom);
        }
        for (const b of [0, 0.25, 0.5, 0.75, 1]) {
            cr.moveTo(box.left, y(b));
            cr.lineTo(w - box.right, y(b));
        }
        cr.stroke();
        ink(0.5);
        for (const [l, label] of [[0, '0'], [10, '10'], [100, '100'], [1000, '1000'], [10000, '10 000 lx']])
            text(label, x(l), h - box.bottom / 2, l === 10000 ? 0.85 : 0.5);
        for (const b of [0, 0.5, 1])
            text(`${b * 100}%`, box.left - 8, y(b), 1);

        // Where the keyboard turns off.
        if (settings.get_boolean('keyboard')) {
            const kx = x(settings.get_int('keyboard-off-lux'));
            ink(0.3);
            cr.setDash([4, 4], 0);
            cr.moveTo(kx, box.top);
            cr.lineTo(kx, h - box.bottom);
            cr.stroke();
            cr.setDash([], 0);
            ink(0.5);
            text(_('keyboard off'), kx - 6, box.top + 10, 1);
        }

        // The curve, under it a light fill.
        const steps = 240;
        const at = i => 10 ** (position(GRAPH_MAX_LUX) * i / steps) - 1;
        cr.moveTo(x(0), y(0));
        for (let i = 0; i <= steps; i++)
            cr.lineTo(x(at(i)), y(target(at(i), points)));
        cr.lineTo(x(GRAPH_MAX_LUX), y(0));
        cr.closePath();
        cr.setSourceRGBA(accent.red, accent.green, accent.blue, 0.12);
        cr.fill();
        for (let i = 0; i <= steps; i++) {
            const px = x(at(i)), py = y(target(at(i), points));
            if (i === 0)
                cr.moveTo(px, py);
            else
                cr.lineTo(px, py);
        }
        cr.setSourceRGBA(accent.red, accent.green, accent.blue, 1);
        cr.setLineWidth(2.5);
        cr.stroke();

        // The points to drag; the one in hand shows its value (drawn last, on top).
        let label = null;
        BANDS.forEach((l, i) => {
            const active = i === dragging || (dragging < 0 && i === hover);
            cr.newSubPath();
            cr.arc(x(l), y(points[i]), active ? POINT_RADIUS + 2 : POINT_RADIUS, 0, 2 * Math.PI);
            cr.setSourceRGBA(accent.red, accent.green, accent.blue, 1);
            cr.fillPreserve();
            // Outlined in the card's colour, so the points read on the line in light and dark.
            if (style.dark)
                cr.setSourceRGBA(0.21, 0.21, 0.23, 1);
            else
                cr.setSourceRGBA(1, 1, 1, 1);
            cr.setLineWidth(2.5);
            cr.stroke();
            if (active) {
                // Above the point, or under it when there's no room above.
                const py = y(points[i]);
                label = [`${Math.round(points[i] * 100)}% · ${l} lx`, x(l),
                    py - 20 < box.top ? py + 20 : py - 20,
                    i === 0 ? 0.1 : i === BANDS.length - 1 ? 0.9 : 0.5];
            }
        });

        // The room now.
        const lux = getLux();
        if (lux !== null) {
            const px = x(lux), py = y(target(lux, points));
            ink(0.25);
            cr.setLineWidth(1);
            cr.moveTo(px, py);
            cr.lineTo(px, h - box.bottom);
            cr.stroke();
            ink(0.95);
            cr.newSubPath();
            cr.arc(px, py, 5, 0, 2 * Math.PI);
            cr.fill();
        }

        if (label) {
            ink(0.95);
            text(label[0], label[1], label[2], label[3], true);
        }
        cr.$dispose();
    });
    return area;
}

export default class AutoBrightnessPrefs extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const settings = this.getSettings();
        const power = new Gio.Settings({schema_id: POWER_SCHEMA});
        let lux = null;
        window.set_default_size(660, 900);

        const page = new Adw.PreferencesPage();
        window.add(page);

        // On/off is GNOME's own switch, so it's the same one Settings and Quick Settings show.
        const intro = new Adw.PreferencesGroup({
            description: _('The screen follows the light in the room. The brightness slider still works: ' +
                'below the middle the screen is darker than the curve, above it brighter.'),
        });
        const toggle = new Adw.SwitchRow({
            title: _('Automatic Screen Brightness'),
            subtitle: _('The same switch as in Quick Settings and in Settings → Power'),
        });
        power.bind('ambient-enabled', toggle, 'active', Gio.SettingsBindFlags.DEFAULT);
        intro.add(toggle);
        page.add(intro);

        const curve = new Adw.PreferencesGroup({
            title: _('Brightness Curve'),
            description: _('Drag the points to set the brightness for each light level. The dot is the room now.'),
        });
        curve.set_header_suffix(resetButton(() => settings.reset('points')));
        const editor = curveEditor(settings, () => lux);
        // A row of the group's list, so the graph and the rows under it are one card.
        curve.add(new Adw.PreferencesRow({child: editor, activatable: false, selectable: false, focusable: false}));
        const room = new Adw.ActionRow({title: _('Light in the room'), subtitle: _('Waiting for the sensor…')});
        const roomValue = new Gtk.Label({css_classes: ['numeric', 'dim-label']});
        room.add_suffix(roomValue);
        curve.add(room);
        const response = spinRow(settings, 'response', _('Reaction time'),
            _('Seconds to catch up with a brighter room; dimming takes three times longer'),
            {min: 0.2, max: 10, step: 0.1, digits: 1});
        curve.add(response);
        page.add(curve);

        const keyboard = new Adw.PreferencesGroup({
            title: _('Keyboard Backlight'),
            description: _('On in the dark, off above the dashed line. Changing the keyboard brightness while it\'s lit sets its level.'),
        });
        keyboard.set_header_suffix(resetButton(() => KEYBOARD_KEYS.forEach(k => settings.reset(k))));
        const kbdToggle = new Adw.SwitchRow({
            title: _('Follows the room'),
            subtitle: _('Also in the Auto Brightness menu in Quick Settings'),
        });
        settings.bind('keyboard', kbdToggle, 'active', Gio.SettingsBindFlags.DEFAULT);
        keyboard.add(kbdToggle);
        const kbdOff = spinRow(settings, 'keyboard-off-lux', _('Turns off above'),
            '', {min: 1, max: 2000, step: 5, digits: 0});
        const kbdRows = [
            spinRow(settings, 'keyboard-level', _('Brightness in the dark'),
                _('Percent'), {min: 1, max: 100, step: 5, digits: 0}),
            kbdOff,
        ];
        for (const row of kbdRows) {
            settings.bind('keyboard', row, 'sensitive', Gio.SettingsBindFlags.GET);
            keyboard.add(row);
        }
        page.add(keyboard);

        const update = () => {
            const off = settings.get_int('keyboard-off-lux');
            kbdOff.subtitle = _('Lux; back on below {on}')
                .replace('{on}', String(Math.round(off * KEYBOARD_ON_SHARE)));
            if (lux !== null) {
                room.subtitle = _('{lux} lux: {what}')
                    .replace('{lux}', String(Math.round(lux))).replace('{what}', describeLux(lux));
                roomValue.label = _('screen {percent}%')
                    .replace('{percent}', String(Math.round(target(lux, readCurve(settings)) * 100)));
            }
            editor.queue_draw();
        };
        settings.connect('changed', update);
        update();

        // The live reading: hold the sensor while this window is open.
        let proxy = null;
        new SensorProxy(Gio.DBus.system, 'net.hadess.SensorProxy', '/net/hadess/SensorProxy', (p, error) => {
            if (error || !p.HasAmbientLight) {
                room.subtitle = _('No light sensor found');
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
