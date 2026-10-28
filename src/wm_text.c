#include "wm_text.h"
#include <pango/pangocairo.h>
#include <string.h>

/* Menus and the Clip draw and measure a lot of short strings in the same one
 * or two fonts. What is costly there is not the text but the setup around it:
 * parsing the font description, creating a Pango context and layout, and (for
 * measuring) a cairo surface. All of it is kept and reused. The program is
 * single-threaded. */

#define FONT_SLOTS 4

static struct {
    char *name;
    PangoFontDescription *desc;
} font_cache[FONT_SLOTS];
static int font_next;

/* The parsed description of `font`; owned by the cache. */
static const PangoFontDescription *font_for(const char *font) {
    for (int i = 0; i < FONT_SLOTS; i++) {
        if (font_cache[i].name && strcmp(font_cache[i].name, font) == 0)
            return font_cache[i].desc;
    }
    int slot = font_next;
    font_next = (font_next + 1) % FONT_SLOTS;
    if (font_cache[slot].name) {
        g_free(font_cache[slot].name);
        pango_font_description_free(font_cache[slot].desc);
    }
    font_cache[slot].name = g_strdup(font);
    font_cache[slot].desc = pango_font_description_from_string(font);
    return font_cache[slot].desc;
}

/* The layout used for drawing: a layout belongs to a Pango context, not to the
 * cairo context it was made from, so one serves every canvas as long as it is
 * brought up to date with the target before each use. */
static PangoLayout *draw_layout;

/* Measuring: a 1x1 scratch surface and its own layout. */
static cairo_surface_t *scratch_surface;
static cairo_t *scratch_cr;
static PangoLayout *scratch_layout;

void wm_draw_text(cairo_t *cr, const char *text, int x, int y, const char *font) {
    if (!draw_layout) {
        draw_layout = pango_cairo_create_layout(cr);
        if (!draw_layout) return;
    } else {
        pango_cairo_update_layout(cr, draw_layout);
    }
    pango_layout_set_font_description(draw_layout, font_for(font));
    pango_layout_set_text(draw_layout, text, -1);
    cairo_move_to(cr, x, y);
    pango_cairo_show_layout(cr, draw_layout);
}

void wm_measure_text(const char *text, const char *font, int *w, int *h) {
    *w = 0;
    *h = 0;
    if (!scratch_layout) {
        scratch_surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
        scratch_cr = cairo_create(scratch_surface);
        scratch_layout = pango_cairo_create_layout(scratch_cr);
        if (!scratch_layout) return;
    }
    pango_layout_set_font_description(scratch_layout, font_for(font));
    pango_layout_set_text(scratch_layout, text, -1);
    pango_layout_get_pixel_size(scratch_layout, w, h);
}