// The brightness curve, shared by the extension and its settings window.

/** The curve's settings, from the extension's GSettings. */
export function readCurve(settings) {
    return {
        darkLevel: settings.get_double('dark-level'),
        brightLux: settings.get_int('bright-lux'),
        curve: settings.get_double('curve'),
    };
}

/**
 * The screen brightness (0–1) for a light level. Eyes see light on a log
 * scale, so the curve runs over log(lux): from darkLevel at 0 lux to full
 * brightness at brightLux, bent by curve (1 = straight).
 */
export function target(lux, {darkLevel, brightLux, curve}) {
    const x = Math.min(1, Math.log10(1 + Math.max(0, lux)) / Math.log10(1 + brightLux));
    return darkLevel + (1 - darkLevel) * x ** curve;
}
