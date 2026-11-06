#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <pango/pangocairo.h>

// Measure the generated stamp line, including Pango's alignment and HiDPI scale.
// Never frame a wrapped label, a summary, or arbitrary notification body text.
static bool foxml_stamp_bounds(PangoLayout *layout, PangoRectangle *bounds) {
    const char *text = pango_layout_get_text(layout);
    const char *newline = strchr(text, '\n');
    if (!newline) return false;
    size_t length = newline - text;
    const char *labels[] = {" RECEIVED ", " SAVED ", " COPIED ", " READY "};
    bool known = false;
    for (unsigned i = 0; i < sizeof(labels) / sizeof(labels[0]); ++i) {
        if (length == strlen(labels[i]) && memcmp(text, labels[i], length) == 0) known = true;
    }
    PangoLayoutLine *line = pango_layout_get_line_readonly(layout, 0);
    if (!known || !line || line->length != (int)length) return false;
    PangoLayoutIter *iter = pango_layout_get_iter(layout);
    pango_layout_iter_get_line_extents(iter, NULL, bounds);
    pango_layout_iter_free(iter);
    return bounds->width > 0 && bounds->height > 0;
}

static void foxml_stamp_pad(cairo_t *cr, double x, double y, double rx, double ry) {
    cairo_save(cr);
    cairo_translate(cr, x, y);
    cairo_scale(cr, rx, ry);
    cairo_new_sub_path(cr);
    cairo_arc(cr, 0, 0, 1, 0, 6.2832);
    cairo_restore(cr);
}

static void foxml_stamp_frame(cairo_t *cr, PangoLayout *layout,
        double origin_x, double origin_y, uint32_t ink, int scale) {
    PangoRectangle bounds;
    if (!foxml_stamp_bounds(layout, &bounds)) return;
    double x = origin_x + bounds.x / (double)PANGO_SCALE - 2 * scale;
    double y = origin_y + bounds.y / (double)PANGO_SCALE - 2 * scale;
    double w = bounds.width / (double)PANGO_SCALE + 4 * scale;
    double h = bounds.height / (double)PANGO_SCALE + 4 * scale;
    cairo_save(cr);
    cairo_set_source_rgba(cr, (ink >> 24 & 255) / 255.,
        (ink >> 16 & 255) / 255., (ink >> 8 & 255) / 255., (ink & 255) / 255. * .38);
    cairo_set_line_width(cr, .7 * scale);
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    // A few fixed ink gaps suggest a lightly pressed rubber stamp.
    cairo_new_path(cr);
    cairo_move_to(cr, x + w * .28, y);
    cairo_line_to(cr, x + 1.5 * scale, y);
    cairo_line_to(cr, x, y + h * .72);
    cairo_move_to(cr, x, y + h * .83);
    cairo_line_to(cr, x + .35 * scale, y + h);
    cairo_line_to(cr, x + w * .63, y + h);
    cairo_move_to(cr, x + w * .69, y + h);
    cairo_line_to(cr, x + w, y + h - .3 * scale);
    cairo_line_to(cr, x + w, y + 1.2 * scale);
    cairo_line_to(cr, x + w * .37, y);
    cairo_stroke(cr);
    // A small paw beside the frame, in the same faint stamp ink.
    double px = x + w + 8 * scale, py = y + h / 2 + scale;
    cairo_new_path(cr);
    foxml_stamp_pad(cr, px, py + scale, 2.6 * scale, 2.1 * scale);
    foxml_stamp_pad(cr, px - 3.4 * scale, py - 1.4 * scale, 1.05 * scale, 1.3 * scale);
    foxml_stamp_pad(cr, px - 1.2 * scale, py - 3.4 * scale, 1.05 * scale, 1.35 * scale);
    foxml_stamp_pad(cr, px + 1.2 * scale, py - 3.4 * scale, 1.05 * scale, 1.35 * scale);
    foxml_stamp_pad(cr, px + 3.4 * scale, py - 1.4 * scale, 1.05 * scale, 1.3 * scale);
    cairo_fill(cr);
    cairo_restore(cr);
}
