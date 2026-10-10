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
    GB_E_RESOURCE_OPERATION = -15,
    GB_E_SUBMIT_OPERATION = -16,
    GB_E_TRANSFER_OPERATION = -17,
    GB_E_FENCE_OPERATION = -18,
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

/*
 * Resource and context calls. Every buffer passed in is borrowed for the call
 * only: virglrenderer copies or reads it before returning, and keeps no
 * pointer into it. The caller sizes each buffer to the bytes the renderer will
 * touch (graphics.md §4.4, §5.4).
 */

/* Binds a resource to a context (CTX_ATTACH_RESOURCE). */
int gb_ctx_attach_resource(gb_renderer *renderer, uint32_t ctx_id, uint32_t res_id);

/* Unbinds a resource from a context (CTX_DETACH_RESOURCE). */
void gb_ctx_detach_resource(gb_renderer *renderer, uint32_t ctx_id, uint32_t res_id);

/*
 * Submits a VirGL command stream. The stream is copied when it is not 4-byte
 * aligned. A nonzero `size_bytes` that is a multiple of 4 is required.
 */
int gb_submit(gb_renderer *renderer, uint32_t ctx_id, const void *commands, size_t size_bytes);

typedef struct {
    uint32_t resource_id;
    uint32_t target;
    uint32_t format;
    uint32_t bind;
    uint32_t width;
    uint32_t height;
    uint32_t depth;
    uint32_t array_size;
    uint32_t last_level;
    uint32_t sample_count;
    uint32_t flags;
} gb_resource_args;

/* Creates a resource (RESOURCE_CREATE_2D or RESOURCE_CREATE_3D). */
int gb_resource_create(gb_renderer *renderer, const gb_resource_args *args);

/* Destroys a resource and detaches it from every context. */
void gb_resource_unref(gb_renderer *renderer, uint32_t res_id);

typedef struct {
    uint32_t resource_id;
    uint32_t ctx_id;
    uint32_t level;
    uint32_t stride;
    uint32_t layer_stride;
    uint32_t x;
    uint32_t y;
    uint32_t z;
    uint32_t width;
    uint32_t height;
    uint32_t depth;
} gb_transfer_args;

/*
 * Copies bytes from `buffer` into the box of the resource (TRANSFER_TO_HOST).
 * `buffer` begins at the resource origin: the caller has already gathered the
 * guest bytes from the transfer's offset, so the renderer reads from offset 0.
 */
int gb_transfer_write(
    gb_renderer *renderer,
    const gb_transfer_args *args,
    void *buffer,
    size_t buffer_bytes
);

/*
 * Copies the box out of the resource into `buffer` (TRANSFER_FROM_HOST). This
 * is a GPU-to-CPU read. It is counted by the caller, never by the bridge.
 */
int gb_transfer_read(
    gb_renderer *renderer,
    const gb_transfer_args *args,
    void *buffer,
    size_t buffer_bytes
);

/*
 * Creates a fence on the global timeline. It completes through the
 * `write_fence` callback, which runs on the render thread during `gb_poll`
 * or another call. Fences are 32-bit because virglrenderer's ctx0 fences are.
 */
int gb_create_fence(gb_renderer *renderer, uint32_t fence_id, uint32_t ctx_id);

/* Lets virglrenderer retire completed fences. Call on the render thread. */
void gb_poll(gb_renderer *renderer);

#if defined(DEBUG)
/* Test-only probe for the signed-app runtime locator. */
bool gb_debug_app_bundle_runtime_is_valid(const char *executable_path);
#endif

#endif
