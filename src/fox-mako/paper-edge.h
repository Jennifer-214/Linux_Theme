// FoxML's only drawing extension. Upstream Mako still owns notifications,
// actions, history, DND, progress clipping, scaling and Wayland placement.
#pragma once
#include <cairo/cairo.h>

static void foxml_paper_path(cairo_t *cr, double x, double y, double w,
        double h, int scale, int shape) {
    cairo_save(cr);
    cairo_scale(cr, scale, scale);
    cairo_translate(cr, x, y);
    cairo_new_sub_path(cr);
    if (shape == 1) {
        // Same 14px-wide, 6px-deep bookmark cut as BarRibbon.qml.
        cairo_move_to(cr, 0, 0); cairo_line_to(cr, w, 0);
        cairo_line_to(cr, w, h - 4);
        cairo_curve_to(cr, w, h, w, h, w - 4, h);
        cairo_line_to(cr, w / 2 + 7, h);
        cairo_line_to(cr, w / 2, h - 6);
        cairo_line_to(cr, w / 2 - 7, h);
        cairo_line_to(cr, 4, h);
        cairo_curve_to(cr, 0, h, 0, h, 0, h - 4);
        cairo_line_to(cr, 0, 0);
    } else {
        // Optional receipt treatment, confined to the lower edge.
        cairo_move_to(cr, 4, 0); cairo_line_to(cr, w - 4, 0);
        cairo_curve_to(cr, w, 0, w, 0, w, 4);
        cairo_line_to(cr, w, h - 3);
        int count = (int)(w / 12); if (count < 1) count = 1;
        double step = w / count;
        for (int i = 0; i < count; ++i) {
            double at = w - i * step;
            cairo_curve_to(cr, at - step * .75, h, at - step * .25, h, at - step, h - 3);
        }
        cairo_line_to(cr, 0, 4);
        cairo_curve_to(cr, 0, 0, 0, 0, 4, 0);
    }
    cairo_close_path(cr);
    cairo_restore(cr);
}
