// SPDX-License-Identifier: GPL-3.0
//
// A wlr_buffer that owns a copy of ARGB8888 pixels. The Dock shows its tiles
// with these (dock_scene.zig). wlroots lets a buffer be made only by giving it
// an implementation, and that part of its API is C, so it is C here.

#ifndef WM_PIXBUF_H
#define WM_PIXBUF_H

#include <stddef.h>

struct wlr_buffer;

/// Copy `stride * height` bytes of premultiplied ARGB8888 (little endian, as
/// cairo makes it) into a new buffer. The caller holds the only reference:
/// hand it to the scene (which locks it) and `wlr_buffer_drop` it, and it
/// goes away when the scene lets go. NULL if out of memory.
struct wlr_buffer *wm_pixbuf_create(int width, int height, const void *argb, size_t stride);

#endif