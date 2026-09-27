#include "wm_text.h"
#include <pango/pangocairo.h>

static PangoLayout *make_layout(cairo_t *cr, const char *text, const char *font) {
    PangoLayout *layout = pango_cairo_create_layout(cr);
    PangoFontDescription *desc = pango_font_description_from_string(font);
    pango_layout_set_font_description(layout, desc);
    pango_font_description_free(desc);
    pango_layout_set_text(layout, text, -1);
    return layout;
}

void wm_draw_text(cairo_t *cr, const char *text, int x, int y, const char *font) {
    PangoLayout *layout = make_layout(cr, text, font);
    cairo_move_to(cr, x, y);
    pango_cairo_show_layout(cr, layout);
    g_object_unref(layout);
}

void wm_measure_text(const char *text, const char *font, int *w, int *h) {
    *w = 0;
    *h = 0;
    cairo_surface_t *s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
    cairo_t *cr = cairo_create(s);
    PangoLayout *layout = make_layout(cr, text, font);
    pango_layout_get_pixel_size(layout, w, h);
    g_object_unref(layout);
    cairo_destroy(cr);
    cairo_surface_destroy(s);
}