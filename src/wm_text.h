#ifndef WM_TEXT_H
#define WM_TEXT_H
#include <cairo.h>

void wm_draw_text(cairo_t *cr, const char *text, int x, int y, const char *font);
void wm_measure_text(const char *text, const char *font, int *w, int *h);

#endif