#ifndef APKRUN_GRAPHICS_BRIDGE_H
#define APKRUN_GRAPHICS_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct gb_renderer gb_renderer;

enum {
    GB_OK = 0,
    GB_E_INVALID_ARGUMENT = -1,
    GB_E_RUNTIME_DIRECTORY_MISSING = -2,
    GB_E_LIBRARY_MISSING_VIRGL = -3,
    GB_E_LIBRARY_MISSING_EPOXY = -4,
    GB_E_LIBRARY_MISSING_EGL = -5,
    GB_E_LIBRARY_MISSING_GLES = -6,
    GB_E_EGL_INITIALIZATION = -7,
    GB_E_METAL_DEVICE = -8,
    GB_E_VIRGL_INITIALIZATION = -9,
    GB_E_CAPSET_UNAVAILABLE = -10,
    GB_E_BUFFER_TOO_SMALL = -11,
    GB_E_CONTEXT_CREATION = -12,
    GB_E_RENDERER_ALREADY_EXISTS = -13,
    GB_E_WRONG_THREAD = -14,
};

enum {
    GB_CAPSET_VIRGL = 1,
    GB_CAPSET_VIRGL2 = 2,
};

enum {
    GB_LOG_DEBUG = 0,
    GB_LOG_INFO = 1,
    GB_LOG_WARNING = 2,
    GB_LOG_ERROR = 3,
};

typedef struct {
    /* Called on the render thread when virglrenderer signals a fence. */
    void (*write_fence)(void *user, uint32_t fence_id);
    /* Called on the render thread. `message` is borrowed for this call. */
    void (*log)(void *user, int level, const char *message);
} gb_callbacks;

/*
 * Create, use, and destroy a renderer on the same dedicated render thread.
 * Calls on a live renderer from another thread return GB_E_WRONG_THREAD
 * without changing state. Callers must finish and synchronize every in-flight
 * call before destroy; a handle must not be used after successful destroy.
 * The virglrenderer library has one process-wide renderer state.
 */

/* Returns a stable, process-lifetime description for a bridge status code. */
const char *gb_status_description(int status);

/*
 * Creates the Metal-backed EGL and virglrenderer state. `user` is borrowed
 * until `gb_renderer_destroy`; `cb` is copied when non-NULL.
 */
int gb_renderer_create(const gb_callbacks *cb, void *user, gb_renderer **out);

/*
 * Releases renderer resources. Call on the render thread after all calls on
 * this handle have finished. The handle is invalid after successful destroy.
 */
int gb_renderer_destroy(gb_renderer *renderer);

/*
 * Resets all renderer-owned contexts and resources. Call on the render thread;
 * the caller must discard every guest-derived renderer ID after reset.
 */
int gb_renderer_reset(gb_renderer *renderer);

/*
 * Returns ANGLE's retained Metal device, borrowed until renderer destruction.
 * `out` is set to NULL on failure.
 */
int gb_renderer_metal_device(gb_renderer *renderer, void **out);

/* Writes zero outputs on failure. The capset must be available. */
int gb_capset_info(
    gb_renderer *renderer,
    uint32_t capset_id,
    uint32_t *max_version,
    uint32_t *max_size_bytes
);

/*
 * Fills a capset only when `out_size_bytes` covers the reported maximum size.
 */
int gb_capset_fill(
    gb_renderer *renderer,
    uint32_t capset_id,
    uint32_t version,
    void *out,
    size_t out_size_bytes
);

/* Creates a virgl context. `name` is a borrowed NUL-terminated UTF-8 string. */
int gb_ctx_create(gb_renderer *renderer, uint32_t ctx_id, const char *name);

/* Destroys a virgl context if the renderer is valid. */
int gb_ctx_destroy(gb_renderer *renderer, uint32_t ctx_id);

#if defined(DEBUG)
/* Test-only probe for the signed-app runtime locator. */
bool gb_debug_app_bundle_runtime_is_valid(const char *executable_path);
#endif

#endif
