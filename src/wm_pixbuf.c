// SPDX-License-Identifier: GPL-3.0
#define WLR_USE_UNSTABLE
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <wlr/types/wlr_buffer.h>

#include "wm_pixbuf.h"

// DRM_FORMAT_ARGB8888 ('A' 'R' '2' '4'); spelled out so that libdrm's
// headers are not needed just for one number.
#define WM_FORMAT_ARGB8888 0x34325241u

struct wm_pixbuf {
    struct wlr_buffer base;
    size_t stride;
    void *data;
};

static void pixbuf_destroy(struct wlr_buffer *buffer) {
    struct wm_pixbuf *pb = (struct wm_pixbuf *)buffer;
    free(pb->data);
    free(pb);
}

static bool pixbuf_begin_data_ptr_access(struct wlr_buffer *buffer, uint32_t flags,
        void **data, uint32_t *format, size_t *stride) {
    // Read only: nobody draws into a tile that is on show.
    if (flags & WLR_BUFFER_DATA_PTR_ACCESS_WRITE) {
        return false;
    }
    struct wm_pixbuf *pb = (struct wm_pixbuf *)buffer;
    *data = pb->data;
    *format = WM_FORMAT_ARGB8888;
    *stride = pb->stride;
    return true;
}

static void pixbuf_end_data_ptr_access(struct wlr_buffer *buffer) {
    (void)buffer;
}

static const struct wlr_buffer_impl pixbuf_impl = {
    .destroy = pixbuf_destroy,
    .begin_data_ptr_access = pixbuf_begin_data_ptr_access,
    .end_data_ptr_access = pixbuf_end_data_ptr_access,
};

struct wlr_buffer *wm_pixbuf_create(int width, int height, const void *argb, size_t stride) {
    if (width <= 0 || height <= 0 || argb == NULL || stride < (size_t)width * 4) {
        return NULL;
    }
    struct wm_pixbuf *pb = calloc(1, sizeof(*pb));
    if (pb == NULL) {
        return NULL;
    }
    size_t size = stride * (size_t)height;
    pb->data = malloc(size);
    if (pb->data == NULL) {
        free(pb);
        return NULL;
    }
    memcpy(pb->data, argb, size);
    pb->stride = stride;
    wlr_buffer_init(&pb->base, &pixbuf_impl, width, height);
    return &pb->base;
}