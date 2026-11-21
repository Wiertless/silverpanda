// The brightness curve, shared by the extension and its settings window.
//
// Brightness is set at fixed light levels (like an equalizer's bands) and
// joined by a smooth line that never goes down (monotone cubic, over log(lux):
// eyes see light on a log scale). The defaults follow measured preferences:
// about 11, 68 and 257 cd/m² at 0, 100 and 500 lux (review in Applied
// Sciences 11(9):4108), for a ~500 cd/m² laptop panel, a little brighter at
// the bottom as phone curves are, and full brightness near the top of what
// laptop light sensors read (~3300 lux).

/** The light levels the points sit at, in lux. */
export const BANDS = [0, 10, 50, 150, 500, 1500, 3500];
/** Screen brightness (0–1) at each band, by default. */
export const DEFAULT_POINTS = [0.03, 0.08, 0.15, 0.25, 0.5, 0.8, 1.0];

/** Where a light level sits on the curve's axis. */
export const position = lux => Math.log10(1 + Math.max(0, lux));

/** The points from the extension's GSettings (the defaults if they don't fit). */
export function readCurve(settings) {
    const points = settings.get_value('points').deepUnpack();
    return points.length === BANDS.length ? points : DEFAULT_POINTS;
}

/** Make the points rise: moving point `fixed` pushes the others out of its way. */
export function keepRising(points, fixed) {
    const p = [...points];
    for (let i = fixed + 1; i < p.length; i++)
        p[i] = Math.max(p[i], p[i - 1]);
    for (let i = fixed - 1; i >= 0; i--)
        p[i] = Math.min(p[i], p[i + 1]);
    return p;
}

// Fritsch–Carlson slopes, so the line between rising points doesn't overshoot.
function slopes(xs, ys) {
    const n = xs.length;
    const d = [];
    for (let i = 0; i < n - 1; i++)
        d.push((ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]));
    const m = [d[0]];
    for (let i = 1; i < n - 1; i++)
        m.push(d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2);
    m.push(d[n - 2]);
    for (let i = 0; i < n - 1; i++) {
        if (d[i] === 0) {
            m[i] = m[i + 1] = 0;
            continue;
        }
        const a = m[i] / d[i], b = m[i + 1] / d[i];
        const s = a * a + b * b;
        if (s > 9) {
            const t = 3 / Math.sqrt(s);
            m[i] = t * a * d[i];
            m[i + 1] = t * b * d[i];
        }
    }
    return m;
}

/** The screen brightness (0–1) for a light level. */
export function target(lux, points) {
    const xs = BANDS.map(position);
    const x = position(lux);
    if (x <= xs[0])
        return points[0];
    if (x >= xs[xs.length - 1])
        return points[points.length - 1];
    const m = slopes(xs, points);
    let i = 0;
    while (x > xs[i + 1])
        i++;
    const h = xs[i + 1] - xs[i];
    const t = (x - xs[i]) / h;
    const y = (2 * t ** 3 - 3 * t ** 2 + 1) * points[i] + (t ** 3 - 2 * t ** 2 + t) * h * m[i] +
        (-2 * t ** 3 + 3 * t ** 2) * points[i + 1] + (t ** 3 - t ** 2) * h * m[i + 1];
    return Math.min(1, Math.max(0, y));
}
