#import <Foundation/Foundation.h>

#include "GraphicsBridge.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <virgl/virglrenderer.h>

#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>

/* The layout of virgl_box in virgl_hw.h, which the installed headers do not ship. */
struct virgl_box {
    uint32_t x, y, z;
    uint32_t w, h, d;
};

struct gb_egl_api {
    PFNEGLGETPROCADDRESSPROC get_proc_address;
    PFNEGLINITIALIZEPROC initialize;
    PFNEGLBINDAPIPROC bind_api;
    PFNEGLCHOOSECONFIGPROC choose_config;
    PFNEGLCREATEPBUFFERSURFACEPROC create_pbuffer_surface;
    PFNEGLCREATECONTEXTPROC create_context;
    PFNEGLMAKECURRENTPROC make_current;
    PFNEGLDESTROYCONTEXTPROC destroy_context;
    PFNEGLDESTROYSURFACEPROC destroy_surface;
    PFNEGLTERMINATEPROC terminate;
    PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display;
    PFNEGLQUERYDISPLAYATTRIBEXTPROC query_display_attrib;
    PFNEGLQUERYDEVICEATTRIBEXTPROC query_device_attrib;
};

struct gb_virgl_api {
    int (*renderer_init)(void *cookie, int flags, struct virgl_renderer_callbacks *callbacks);
    void (*renderer_cleanup)(void *cookie);
    void (*renderer_reset)(void);
    void (*renderer_get_cap_set)(uint32_t, uint32_t *, uint32_t *);
    void (*renderer_fill_caps)(uint32_t, uint32_t, void *);
    int (*renderer_context_create)(uint32_t, uint32_t, const char *);
    void (*renderer_context_destroy)(uint32_t);
    void (*set_log_callback)(virgl_log_callback_type, void *, virgl_free_data_callback_type);
    int (*resource_create)(struct virgl_renderer_resource_create_args *, struct iovec *, uint32_t);
    void (*resource_unref)(uint32_t);
    int (*resource_attach_iov)(int, struct iovec *, int);
    void (*resource_detach_iov)(int, struct iovec **, int *);
    void (*ctx_attach_resource)(int, int);
    void (*ctx_detach_resource)(int, int);
    int (*submit_cmd)(void *, int, int);
    int (*transfer_write_iov)(
        uint32_t, uint32_t, int, uint32_t, uint32_t,
        struct virgl_box *, uint64_t, struct iovec *, unsigned int);
    int (*transfer_read_iov)(
        uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
        struct virgl_box *, uint64_t, struct iovec *, int);
    int (*create_fence)(int, uint32_t);
    void (*poll)(void);
    /* Optional in older builds. The present path needs it (#023). */
    int (*borrow_texture_for_scanout)(int, struct virgl_renderer_resource_info_ext *);
};

/* The GL entry points of the present path. ANGLE exports them from libGLESv2 (graphics.md §6.2). */
struct gb_present_gl_api {
    void (*bind_framebuffer)(GLenum, GLuint);
    void (*gen_framebuffers)(GLsizei, GLuint *);
    void (*delete_framebuffers)(GLsizei, const GLuint *);
    void (*framebuffer_texture_2d)(GLenum, GLenum, GLenum, GLuint, GLint);
    GLenum (*check_framebuffer_status)(GLenum);
    void (*blit_framebuffer)(GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLbitfield, GLenum);
    void (*gen_textures)(GLsizei, GLuint *);
    void (*delete_textures)(GLsizei, const GLuint *);
    void (*bind_texture)(GLenum, GLuint);
    void (*egl_image_target_texture_2d)(GLenum, GLeglImageOES);
    void (*get_integerv)(GLenum, GLint *);
    void (*get_booleanv)(GLenum, GLboolean *);
    void (*enable)(GLenum);
    void (*disable)(GLenum);
    void (*color_mask)(GLboolean, GLboolean, GLboolean, GLboolean);
    void (*flush)(void);
};

/* The EGL extension entry points of the present path (EGL_KHR_image_base, EGL_KHR_fence_sync). */
struct gb_present_egl_api {
    PFNEGLCREATEIMAGEKHRPROC create_image;
    PFNEGLDESTROYIMAGEKHRPROC destroy_image;
    PFNEGLCREATESYNCKHRPROC create_sync;
    PFNEGLDESTROYSYNCKHRPROC destroy_sync;
    PFNEGLCLIENTWAITSYNCKHRPROC client_wait_sync;
    PFNEGLGETCURRENTCONTEXTPROC get_current_context;
    PFNEGLGETCURRENTSURFACEPROC get_current_surface;
};

/* A present target: the Metal texture of one IOSurface, imported into GL as a framebuffer attachment. */
struct gb_present_target {
    void *metal_texture;
    EGLImageKHR image;
    GLuint texture;
    GLuint framebuffer;
    uint32_t width;
    uint32_t height;
};

/* The EGL state of the calling thread, saved before the present path switches to the root context. */
struct gb_present_saved_state {
    EGLContext context;
    EGLSurface draw;
    EGLSurface read;
};

/* The iovec array that the bridge gave virglrenderer for the backing of one resource (IR-836). */
struct gb_backing_record {
    uint32_t res_id;
    struct iovec *iov;
    struct gb_backing_record *next;
};

struct gb_renderer {
    gb_callbacks callbacks;
    void *user;
    void *epoxy_library;
    void *egl_library;
    void *gles_library;
    void *virgl_library;
    struct gb_egl_api egl;
    struct gb_virgl_api virgl;
    struct gb_present_gl_api gl;
    struct gb_present_egl_api present_egl;
    /* Set when every present entry point loaded. Only the render thread reads it. */
    bool present_ready;
    /* The framebuffer that reads the scanout texture in the root context. Created on first use (#023). */
    GLuint present_source_framebuffer;
    struct virgl_renderer_callbacks virgl_callbacks;
    EGLDisplay display;
    EGLConfig config;
    EGLSurface surface;
    EGLContext root_context;
    void *metal_device;
    bool display_initialized;
    bool virgl_initialized;
    bool log_callback_registered;
    bool owns_process_slot;
    pthread_t render_thread;
    /* The attached backings. The bridge frees each array when its backing is released (IR-836). */
    struct gb_backing_record *backings;
};

static pthread_mutex_t gb_renderer_lock = PTHREAD_MUTEX_INITIALIZER;
static gb_renderer *gb_active_renderer;

static const char *const gb_runtime_libraries[] = {
    "libepoxy.0.dylib",
    "libEGL.dylib",
    "libGLESv2.dylib",
    "libvirglrenderer.1.dylib",
};

static void gb_emit_log(gb_renderer *renderer, int level, const char *message) {
    if (renderer != NULL && renderer->callbacks.log != NULL && message != NULL) {
        renderer->callbacks.log(renderer->user, level, message);
    }
}

static bool gb_is_directory(NSString *path) {
    BOOL is_directory = NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&is_directory]
        && is_directory;
}

static NSString *gb_resolved_path(NSString *path) {
    return [NSURL fileURLWithPath:path].URLByResolvingSymlinksInPath.path.stringByStandardizingPath;
}

static bool gb_path_is_within(NSString *path, NSString *directory) {
    NSString *resolved_path = gb_resolved_path(path);
    NSString *resolved_directory = gb_resolved_path(directory);
    if (resolved_path == nil || resolved_directory == nil) {
        return false;
    }
    NSString *directory_prefix = [resolved_directory stringByAppendingString:@"/"];
    return [resolved_path hasPrefix:directory_prefix];
}

static NSString *gb_executable_path(void) {
    uint32_t capacity = 0;
    (void)_NSGetExecutablePath(NULL, &capacity);
    if (capacity == 0) {
        return nil;
    }

    char *executable_path = calloc(capacity, sizeof(char));
    if (executable_path == NULL) {
        return nil;
    }
    if (_NSGetExecutablePath(executable_path, &capacity) != 0) {
        free(executable_path);
        return nil;
    }

    NSString *path = [NSString stringWithUTF8String:executable_path];
    free(executable_path);
    return path;
}

static NSString *gb_debug_runtime_override(void) {
#if defined(DEBUG)
    const char *override = getenv("APKRUN_VIRGL_RUNTIME_PATH");
    if (override != NULL && override[0] != '\0') {
        return [NSString stringWithUTF8String:override];
    }
#endif
    return nil;
}

static NSString *gb_debug_repository_runtime(void) {
#if defined(DEBUG)
    NSString *executable_path = gb_executable_path();
    if (executable_path == nil) {
        return nil;
    }
    NSURL *cursor = [NSURL fileURLWithPath:executable_path].URLByResolvingSymlinksInPath;
    for (NSUInteger depth = 0; cursor != nil && depth < 12; depth += 1) {
        NSString *development = [[[[cursor URLByAppendingPathComponent:@"ThirdParty"]
            URLByAppendingPathComponent:@"out"]
            URLByAppendingPathComponent:@"virgl-runtime"]
            URLByAppendingPathComponent:@"current"].path;
        if (gb_is_directory(development)) {
            return gb_resolved_path(development);
        }

        NSURL *parent = cursor.URLByDeletingLastPathComponent;
        if ([parent.path isEqualToString:cursor.path]) {
            break;
        }
        cursor = parent;
    }
#endif
    return nil;
}

static NSString *gb_app_bundle_runtime_from_executable(NSString *executable_path) {
    if (executable_path == nil) {
        return nil;
    }
    NSURL *cursor = [NSURL fileURLWithPath:executable_path].URLByResolvingSymlinksInPath;
    for (NSUInteger depth = 0; cursor != nil && depth < 12; depth += 1) {
        if ([cursor.pathExtension isEqualToString:@"app"] && gb_is_directory(cursor.path)) {
            NSString *info_path = [[cursor URLByAppendingPathComponent:@"Contents"]
                URLByAppendingPathComponent:@"Info.plist"].path;
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:info_path];
            NSString *bundle_identifier = info[@"CFBundleIdentifier"];
            NSString *build_identity = info[@"APKRunBuildIdentity"];
            BOOL is_apkrun_bundle =
                [bundle_identifier isEqualToString:@"io.apkrun.APKRun"]
                && [build_identity isEqualToString:@"release"];
            is_apkrun_bundle =
                is_apkrun_bundle
                || ([bundle_identifier isEqualToString:@"io.apkrun.APKRun.updatetest"]
                    && [build_identity isEqualToString:@"updatetest"]);
#if defined(DEBUG)
            is_apkrun_bundle =
                is_apkrun_bundle
                || ([bundle_identifier isEqualToString:@"io.apkrun.APKRun.dev"]
                    && [build_identity isEqualToString:@"dev"]);
#endif
            if (is_apkrun_bundle) {
                NSString *bundle_root = gb_resolved_path(cursor.path);
                NSString *runtime = [[[[cursor URLByAppendingPathComponent:@"Contents"]
                    URLByAppendingPathComponent:@"Frameworks"]
                    URLByAppendingPathComponent:@"VirGLRuntime"].path
                    stringByStandardizingPath];
                if (!gb_is_directory(runtime)
                    || !gb_path_is_within(runtime, bundle_root)) {
                    return nil;
                }
                for (size_t index = 0;
                     index < sizeof(gb_runtime_libraries) / sizeof(gb_runtime_libraries[0]);
                     index += 1) {
                    const char *name = gb_runtime_libraries[index];
                    NSString *library = [runtime stringByAppendingPathComponent:
                        [NSString stringWithUTF8String:name]];
                    if (!gb_path_is_within(library, runtime)) {
                        return nil;
                    }
                }
                return gb_resolved_path(runtime);
            }
        }

        NSURL *parent = cursor.URLByDeletingLastPathComponent;
        if ([parent.path isEqualToString:cursor.path]) {
            break;
        }
        cursor = parent;
    }
    return nil;
}

static NSString *gb_app_bundle_runtime(void) {
    return gb_app_bundle_runtime_from_executable(gb_executable_path());
}

#if defined(DEBUG)
bool gb_debug_app_bundle_runtime_is_valid(const char *executable_path) {
    if (executable_path == NULL || executable_path[0] == '\0') {
        return false;
    }
    NSString *path = [NSString stringWithUTF8String:executable_path];
    return gb_app_bundle_runtime_from_executable(path) != nil;
}
#endif

static NSString *gb_runtime_directory(void) {
    NSString *override = gb_debug_runtime_override();
    if (override != nil) {
        return gb_resolved_path(override);
    }

    NSString *development = gb_debug_repository_runtime();
    if (development != nil) {
        return development;
    }

    return gb_app_bundle_runtime();
}

static void *gb_open_library(gb_renderer *renderer, NSString *directory, const char *name) {
    NSString *path = [directory stringByAppendingPathComponent:
        [NSString stringWithUTF8String:name]];
    if (!gb_path_is_within(path, directory)) {
        gb_emit_log(renderer, GB_LOG_ERROR, "A VirGL runtime library resolves outside its directory.");
        return NULL;
    }
    void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        gb_emit_log(renderer, GB_LOG_ERROR, "A VirGL runtime library could not be loaded.");
    }
    return handle;
}

static void *gb_symbol(void *library, const char *name) {
    if (library == NULL) {
        return NULL;
    }
    (void)dlerror();
    return dlsym(library, name);
}

static void *gb_egl_symbol(gb_renderer *renderer, const char *name) {
    void *symbol = gb_symbol(renderer->egl_library, name);
    if (symbol == NULL && renderer->egl.get_proc_address != NULL) {
        __eglMustCastToProperFunctionPointerType function =
            renderer->egl.get_proc_address(name);
        symbol = (void *)function;
    }
    return symbol;
}

static bool gb_load_egl_api(gb_renderer *renderer) {
    renderer->egl.get_proc_address =
        (PFNEGLGETPROCADDRESSPROC)gb_symbol(renderer->egl_library, "eglGetProcAddress");
    if (renderer->egl.get_proc_address == NULL) {
        return false;
    }

    renderer->egl.initialize =
        (PFNEGLINITIALIZEPROC)gb_egl_symbol(renderer, "eglInitialize");
    renderer->egl.bind_api =
        (PFNEGLBINDAPIPROC)gb_egl_symbol(renderer, "eglBindAPI");
    renderer->egl.choose_config =
        (PFNEGLCHOOSECONFIGPROC)gb_egl_symbol(renderer, "eglChooseConfig");
    renderer->egl.create_pbuffer_surface =
        (PFNEGLCREATEPBUFFERSURFACEPROC)gb_egl_symbol(renderer, "eglCreatePbufferSurface");
    renderer->egl.create_context =
        (PFNEGLCREATECONTEXTPROC)gb_egl_symbol(renderer, "eglCreateContext");
    renderer->egl.make_current =
        (PFNEGLMAKECURRENTPROC)gb_egl_symbol(renderer, "eglMakeCurrent");
    renderer->egl.destroy_context =
        (PFNEGLDESTROYCONTEXTPROC)gb_egl_symbol(renderer, "eglDestroyContext");
    renderer->egl.destroy_surface =
        (PFNEGLDESTROYSURFACEPROC)gb_egl_symbol(renderer, "eglDestroySurface");
    renderer->egl.terminate =
        (PFNEGLTERMINATEPROC)gb_egl_symbol(renderer, "eglTerminate");
    renderer->egl.get_platform_display =
        (PFNEGLGETPLATFORMDISPLAYEXTPROC)gb_egl_symbol(
            renderer,
            "eglGetPlatformDisplayEXT"
        );
    renderer->egl.query_display_attrib =
        (PFNEGLQUERYDISPLAYATTRIBEXTPROC)gb_egl_symbol(
            renderer,
            "eglQueryDisplayAttribEXT"
        );
    renderer->egl.query_device_attrib =
        (PFNEGLQUERYDEVICEATTRIBEXTPROC)gb_egl_symbol(
            renderer,
            "eglQueryDeviceAttribEXT"
        );

    return renderer->egl.initialize != NULL
        && renderer->egl.bind_api != NULL
        && renderer->egl.choose_config != NULL
        && renderer->egl.create_pbuffer_surface != NULL
        && renderer->egl.create_context != NULL
        && renderer->egl.make_current != NULL
        && renderer->egl.destroy_context != NULL
        && renderer->egl.destroy_surface != NULL
        && renderer->egl.terminate != NULL
        && renderer->egl.get_platform_display != NULL
        && renderer->egl.query_display_attrib != NULL
        && renderer->egl.query_device_attrib != NULL;
}

static bool gb_load_virgl_api(gb_renderer *renderer) {
    renderer->virgl.renderer_init =
        (int (*)(void *, int, struct virgl_renderer_callbacks *))
            gb_symbol(renderer->virgl_library, "virgl_renderer_init");
    renderer->virgl.renderer_cleanup =
        (void (*)(void *))gb_symbol(renderer->virgl_library, "virgl_renderer_cleanup");
    renderer->virgl.renderer_reset =
        (void (*)(void))gb_symbol(renderer->virgl_library, "virgl_renderer_reset");
    renderer->virgl.renderer_get_cap_set =
        (void (*)(uint32_t, uint32_t *, uint32_t *))
            gb_symbol(renderer->virgl_library, "virgl_renderer_get_cap_set");
    renderer->virgl.renderer_fill_caps =
        (void (*)(uint32_t, uint32_t, void *))
            gb_symbol(renderer->virgl_library, "virgl_renderer_fill_caps");
    renderer->virgl.renderer_context_create =
        (int (*)(uint32_t, uint32_t, const char *))
            gb_symbol(renderer->virgl_library, "virgl_renderer_context_create");
    renderer->virgl.renderer_context_destroy =
        (void (*)(uint32_t))
            gb_symbol(renderer->virgl_library, "virgl_renderer_context_destroy");
    renderer->virgl.set_log_callback =
        (void (*)(virgl_log_callback_type, void *, virgl_free_data_callback_type))
            gb_symbol(renderer->virgl_library, "virgl_set_log_callback");

    renderer->virgl.resource_create =
        (int (*)(struct virgl_renderer_resource_create_args *, struct iovec *, uint32_t))
            gb_symbol(renderer->virgl_library, "virgl_renderer_resource_create");
    renderer->virgl.resource_unref =
        (void (*)(uint32_t))gb_symbol(renderer->virgl_library, "virgl_renderer_resource_unref");
    renderer->virgl.resource_attach_iov =
        (int (*)(int, struct iovec *, int))gb_symbol(renderer->virgl_library, "virgl_renderer_resource_attach_iov");
    renderer->virgl.resource_detach_iov =
        (void (*)(int, struct iovec **, int *))gb_symbol(renderer->virgl_library, "virgl_renderer_resource_detach_iov");
    renderer->virgl.ctx_attach_resource =
        (void (*)(int, int))gb_symbol(renderer->virgl_library, "virgl_renderer_ctx_attach_resource");
    renderer->virgl.ctx_detach_resource =
        (void (*)(int, int))gb_symbol(renderer->virgl_library, "virgl_renderer_ctx_detach_resource");
    renderer->virgl.submit_cmd =
        (int (*)(void *, int, int))gb_symbol(renderer->virgl_library, "virgl_renderer_submit_cmd");
    renderer->virgl.transfer_write_iov =
        (int (*)(uint32_t, uint32_t, int, uint32_t, uint32_t,
                 struct virgl_box *, uint64_t, struct iovec *, unsigned int))
            gb_symbol(renderer->virgl_library, "virgl_renderer_transfer_write_iov");
    renderer->virgl.transfer_read_iov =
        (int (*)(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                 struct virgl_box *, uint64_t, struct iovec *, int))
            gb_symbol(renderer->virgl_library, "virgl_renderer_transfer_read_iov");
    renderer->virgl.create_fence =
        (int (*)(int, uint32_t))gb_symbol(renderer->virgl_library, "virgl_renderer_create_fence");
    renderer->virgl.poll =
        (void (*)(void))gb_symbol(renderer->virgl_library, "virgl_renderer_poll");
    renderer->virgl.borrow_texture_for_scanout =
        (int (*)(int, struct virgl_renderer_resource_info_ext *))
            gb_symbol(renderer->virgl_library, "virgl_renderer_borrow_texture_for_scanout");

    return renderer->virgl.renderer_init != NULL
        && renderer->virgl.renderer_cleanup != NULL
        && renderer->virgl.renderer_reset != NULL
        && renderer->virgl.renderer_get_cap_set != NULL
        && renderer->virgl.renderer_fill_caps != NULL
        && renderer->virgl.renderer_context_create != NULL
        && renderer->virgl.renderer_context_destroy != NULL
        && renderer->virgl.set_log_callback != NULL
        && renderer->virgl.resource_create != NULL
        && renderer->virgl.resource_unref != NULL
        && renderer->virgl.resource_attach_iov != NULL
        && renderer->virgl.resource_detach_iov != NULL
        && renderer->virgl.ctx_attach_resource != NULL
        && renderer->virgl.ctx_detach_resource != NULL
        && renderer->virgl.submit_cmd != NULL
        && renderer->virgl.transfer_write_iov != NULL
        && renderer->virgl.transfer_read_iov != NULL
        && renderer->virgl.create_fence != NULL
        && renderer->virgl.poll != NULL;
}

static bool gb_is_render_thread(gb_renderer *renderer) {
    return renderer != NULL && pthread_equal(renderer->render_thread, pthread_self()) != 0;
}

static void gb_virgl_write_fence(void *cookie, uint32_t fence_id) {
    gb_renderer *renderer = cookie;
    if (renderer != NULL && renderer->callbacks.write_fence != NULL) {
        renderer->callbacks.write_fence(renderer->user, fence_id);
    }
}

static void gb_virgl_log(
    enum virgl_log_level_flags virgl_level,
    const char *message,
    void *user
) {
    gb_renderer *renderer = user;
    if (renderer == NULL || renderer->callbacks.log == NULL) {
        return;
    }

    int level = GB_LOG_DEBUG;
    switch (virgl_level) {
        case VIRGL_LOG_LEVEL_INFO:
            level = GB_LOG_INFO;
            break;
        case VIRGL_LOG_LEVEL_WARNING:
            level = GB_LOG_WARNING;
            break;
        case VIRGL_LOG_LEVEL_ERROR:
            level = GB_LOG_ERROR;
            break;
        case VIRGL_LOG_LEVEL_DEBUG:
        case VIRGL_LOG_LEVEL_SILENT:
            level = GB_LOG_DEBUG;
            break;
    }
    gb_emit_log(renderer, level, message);
}

static virgl_renderer_gl_context gb_create_gl_context(
    void *cookie,
    int scanout_idx,
    struct virgl_renderer_gl_ctx_param *parameters
) {
    (void)scanout_idx;
    gb_renderer *renderer = cookie;
    if (renderer == NULL || parameters == NULL || parameters->compat_ctx != 0) {
        return NULL;
    }

    /*
     * Every virgl context shares the root context's objects. virglrenderer creates
     * context 0 unshared, but resources made in the root context must stay visible to it.
     */
    EGLContext shared = renderer->root_context;
    EGLint client_version = parameters->major_ver > 0 ? parameters->major_ver : 3;
    const EGLint attributes[] = {
        EGL_CONTEXT_CLIENT_VERSION,
        client_version,
        EGL_NONE,
    };
    return renderer->egl.create_context(
        renderer->display,
        renderer->config,
        shared,
        attributes
    );
}

static void gb_destroy_gl_context(void *cookie, virgl_renderer_gl_context context) {
    gb_renderer *renderer = cookie;
    if (renderer != NULL && context != NULL) {
        (void)renderer->egl.destroy_context(renderer->display, (EGLContext)context);
    }
}

static int gb_make_current(
    void *cookie,
    int scanout_idx,
    virgl_renderer_gl_context context
) {
    (void)scanout_idx;
    gb_renderer *renderer = cookie;
    if (renderer == NULL || renderer->display == EGL_NO_DISPLAY) {
        return -1;
    }

    EGLSurface draw = context == NULL ? EGL_NO_SURFACE : renderer->surface;
    EGLSurface read = context == NULL ? EGL_NO_SURFACE : renderer->surface;
    return renderer->egl.make_current(
        renderer->display,
        draw,
        read,
        (EGLContext)context
    ) == EGL_TRUE ? 0 : -1;
}

static void *gb_get_egl_display(void *cookie) {
    gb_renderer *renderer = cookie;
    return renderer == NULL ? NULL : renderer->display;
}

static int gb_initialize_egl(gb_renderer *renderer) {
    if (!gb_load_egl_api(renderer)) {
        return GB_E_EGL_INITIALIZATION;
    }

    const EGLint display_attributes[] = {
        EGL_PLATFORM_ANGLE_TYPE_ANGLE,
        EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
        EGL_NONE,
    };
    renderer->display = renderer->egl.get_platform_display(
        EGL_PLATFORM_ANGLE_ANGLE,
        EGL_DEFAULT_DISPLAY,
        display_attributes
    );
    if (renderer->display == EGL_NO_DISPLAY) {
        return GB_E_EGL_INITIALIZATION;
    }

    EGLint major = 0;
    EGLint minor = 0;
    if (renderer->egl.initialize(renderer->display, &major, &minor) != EGL_TRUE) {
        return GB_E_EGL_INITIALIZATION;
    }
    renderer->display_initialized = true;

    if (renderer->egl.bind_api(EGL_OPENGL_ES_API) != EGL_TRUE) {
        return GB_E_EGL_INITIALIZATION;
    }

    const EGLint config_attributes[] = {
        EGL_SURFACE_TYPE,
        EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE,
        EGL_OPENGL_ES2_BIT | EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE,
        8,
        EGL_GREEN_SIZE,
        8,
        EGL_BLUE_SIZE,
        8,
        EGL_ALPHA_SIZE,
        8,
        EGL_NONE,
    };
    EGLint config_count = 0;
    if (renderer->egl.choose_config(
            renderer->display,
            config_attributes,
            &renderer->config,
            1,
            &config_count
        ) != EGL_TRUE
        || config_count != 1) {
        return GB_E_EGL_INITIALIZATION;
    }

    const EGLint surface_attributes[] = {
        EGL_WIDTH,
        1,
        EGL_HEIGHT,
        1,
        EGL_NONE,
    };
    renderer->surface = renderer->egl.create_pbuffer_surface(
        renderer->display,
        renderer->config,
        surface_attributes
    );
    if (renderer->surface == EGL_NO_SURFACE) {
        return GB_E_EGL_INITIALIZATION;
    }

    const EGLint context_attributes[] = {
        EGL_CONTEXT_CLIENT_VERSION,
        3,
        EGL_NONE,
    };
    renderer->root_context = renderer->egl.create_context(
        renderer->display,
        renderer->config,
        EGL_NO_CONTEXT,
        context_attributes
    );
    if (renderer->root_context == EGL_NO_CONTEXT) {
        return GB_E_EGL_INITIALIZATION;
    }

    if (renderer->egl.make_current(
            renderer->display,
            renderer->surface,
            renderer->surface,
            renderer->root_context
        ) != EGL_TRUE) {
        return GB_E_EGL_INITIALIZATION;
    }

    EGLAttrib device_attribute = 0;
    if (renderer->egl.query_display_attrib(
            renderer->display,
            EGL_DEVICE_EXT,
            &device_attribute
        ) != EGL_TRUE
        || device_attribute == 0) {
        return GB_E_METAL_DEVICE;
    }

    EGLAttrib metal_attribute = 0;
    if (renderer->egl.query_device_attrib(
            (EGLDeviceEXT)(uintptr_t)device_attribute,
            EGL_METAL_DEVICE_ANGLE,
            &metal_attribute
        ) != EGL_TRUE
        || metal_attribute == 0) {
        return GB_E_METAL_DEVICE;
    }

    id metal_device = (__bridge id)(void *)(uintptr_t)metal_attribute;
    renderer->metal_device = (__bridge_retained void *)metal_device;
    return GB_OK;
}

/*
 * Frees the arrays of every attached backing, without calling virglrenderer. Reset and destroy drop the
 * resources themselves. A detach would copy into guest memory that the reset or the stop may have invalidated
 * (IR-843).
 */
static void gb_free_backing_records(gb_renderer *renderer) {
    struct gb_backing_record *record = renderer->backings;
    while (record != NULL) {
        struct gb_backing_record *next = record->next;
        free(record->iov);
        free(record);
        record = next;
    }
    renderer->backings = NULL;
}

/*
 * Releases the backing of one resource through virglrenderer, then frees the array that the bridge gave it.
 * A resource without backing is left alone. Call only while the guest memory is still mapped (IR-843).
 */
static void gb_detach_backing_record(gb_renderer *renderer, uint32_t res_id) {
    struct gb_backing_record **link = &renderer->backings;
    while (*link != NULL && (*link)->res_id != res_id) {
        link = &(*link)->next;
    }
    struct gb_backing_record *record = *link;
    if (record == NULL) {
        return;
    }
    *link = record->next;
    renderer->virgl.resource_detach_iov((int)res_id, NULL, NULL);
    free(record->iov);
    free(record);
}

static void gb_release_renderer(gb_renderer *renderer) {
    if (renderer == NULL) {
        return;
    }

    if (renderer->virgl_initialized && renderer->virgl.renderer_cleanup != NULL) {
        renderer->virgl.renderer_cleanup(renderer);
        renderer->virgl_initialized = false;
    }
    gb_free_backing_records(renderer);
    if (renderer->log_callback_registered && renderer->virgl.set_log_callback != NULL) {
        renderer->virgl.set_log_callback(NULL, NULL, NULL);
        renderer->log_callback_registered = false;
    }

    if (renderer->display_initialized) {
        (void)renderer->egl.make_current(
            renderer->display,
            EGL_NO_SURFACE,
            EGL_NO_SURFACE,
            EGL_NO_CONTEXT
        );
    }
    if (renderer->root_context != EGL_NO_CONTEXT && renderer->egl.destroy_context != NULL) {
        (void)renderer->egl.destroy_context(renderer->display, renderer->root_context);
    }
    if (renderer->surface != EGL_NO_SURFACE && renderer->egl.destroy_surface != NULL) {
        (void)renderer->egl.destroy_surface(renderer->display, renderer->surface);
    }
    if (renderer->display_initialized && renderer->egl.terminate != NULL) {
        (void)renderer->egl.terminate(renderer->display);
    }
    if (renderer->metal_device != NULL) {
        (void)CFBridgingRelease(renderer->metal_device);
    }

    if (renderer->virgl_library != NULL) {
        (void)dlclose(renderer->virgl_library);
    }
    if (renderer->gles_library != NULL) {
        (void)dlclose(renderer->gles_library);
    }
    if (renderer->egl_library != NULL) {
        (void)dlclose(renderer->egl_library);
    }
    if (renderer->epoxy_library != NULL) {
        (void)dlclose(renderer->epoxy_library);
    }
    if (renderer->owns_process_slot) {
        pthread_mutex_lock(&gb_renderer_lock);
        if (gb_active_renderer == renderer) {
            gb_active_renderer = NULL;
        }
        pthread_mutex_unlock(&gb_renderer_lock);
    }
    free(renderer);
}

const char *gb_status_description(int status) {
    switch (status) {
        case GB_OK:
            return "success";
        case GB_E_INVALID_ARGUMENT:
            return "invalid graphics bridge argument";
        case GB_E_RUNTIME_DIRECTORY_MISSING:
            return "VirGLRuntime directory is missing";
        case GB_E_LIBRARY_MISSING_VIRGL:
            return "libvirglrenderer.1.dylib is missing or could not be loaded";
        case GB_E_LIBRARY_MISSING_EPOXY:
            return "libepoxy.0.dylib is missing or could not be loaded";
        case GB_E_LIBRARY_MISSING_EGL:
            return "libEGL.dylib is missing or could not be loaded";
        case GB_E_LIBRARY_MISSING_GLES:
            return "libGLESv2.dylib is missing or could not be loaded";
        case GB_E_EGL_INITIALIZATION:
            return "ANGLE EGL Metal initialization failed";
        case GB_E_METAL_DEVICE:
            return "ANGLE did not expose its Metal device";
        case GB_E_VIRGL_INITIALIZATION:
            return "virglrenderer initialization failed";
        case GB_E_CAPSET_UNAVAILABLE:
            return "virglrenderer capset is unavailable";
        case GB_E_BUFFER_TOO_SMALL:
            return "capset output buffer is too small";
        case GB_E_CONTEXT_CREATION:
            return "virglrenderer context creation failed";
        case GB_E_RENDERER_ALREADY_EXISTS:
            return "a virglrenderer instance is already active in this process";
        case GB_E_WRONG_THREAD:
            return "graphics renderer called from a thread other than its owner";
        case GB_E_RESOURCE_OPERATION:
            return "virglrenderer rejected a resource operation";
        case GB_E_SUBMIT_OPERATION:
            return "virglrenderer rejected a command stream";
        case GB_E_TRANSFER_OPERATION:
            return "virglrenderer rejected a transfer";
        case GB_E_FENCE_OPERATION:
            return "virglrenderer rejected a fence";
        case GB_E_PRESENT_OPERATION:
            return "the presentation blit failed";
        case GB_SYNC_TIMEOUT:
            return "the presentation fence has not signaled";
        default:
            return "unknown graphics bridge failure";
    }
}

/*
 * Presentation (#023). The present functions use the root context, because the framebuffers they
 * create belong to it. A framebuffer is not shared between GL contexts, and the guest's contexts
 * share only the root's textures (IR-463). Each function saves the EGL context of the caller,
 * switches to the root, and restores the previous context before it returns.
 */

/* Loads the present entry points. A missing entry point leaves `present_ready` false, and the renderer keeps working. */
static void gb_load_present_api(gb_renderer *renderer) {
    renderer->gl.bind_framebuffer =
        (void (*)(GLenum, GLuint))gb_symbol(renderer->gles_library, "glBindFramebuffer");
    renderer->gl.gen_framebuffers =
        (void (*)(GLsizei, GLuint *))gb_symbol(renderer->gles_library, "glGenFramebuffers");
    renderer->gl.delete_framebuffers =
        (void (*)(GLsizei, const GLuint *))gb_symbol(renderer->gles_library, "glDeleteFramebuffers");
    renderer->gl.framebuffer_texture_2d =
        (void (*)(GLenum, GLenum, GLenum, GLuint, GLint))gb_symbol(renderer->gles_library, "glFramebufferTexture2D");
    renderer->gl.check_framebuffer_status =
        (GLenum (*)(GLenum))gb_symbol(renderer->gles_library, "glCheckFramebufferStatus");
    renderer->gl.blit_framebuffer =
        (void (*)(GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLbitfield, GLenum))
            gb_symbol(renderer->gles_library, "glBlitFramebuffer");
    renderer->gl.gen_textures = (void (*)(GLsizei, GLuint *))gb_symbol(renderer->gles_library, "glGenTextures");
    renderer->gl.delete_textures =
        (void (*)(GLsizei, const GLuint *))gb_symbol(renderer->gles_library, "glDeleteTextures");
    renderer->gl.bind_texture = (void (*)(GLenum, GLuint))gb_symbol(renderer->gles_library, "glBindTexture");
    renderer->gl.egl_image_target_texture_2d =
        (void (*)(GLenum, GLeglImageOES))gb_symbol(renderer->gles_library, "glEGLImageTargetTexture2DOES");
    renderer->gl.get_integerv = (void (*)(GLenum, GLint *))gb_symbol(renderer->gles_library, "glGetIntegerv");
    renderer->gl.get_booleanv = (void (*)(GLenum, GLboolean *))gb_symbol(renderer->gles_library, "glGetBooleanv");
    renderer->gl.enable = (void (*)(GLenum))gb_symbol(renderer->gles_library, "glEnable");
    renderer->gl.disable = (void (*)(GLenum))gb_symbol(renderer->gles_library, "glDisable");
    renderer->gl.color_mask =
        (void (*)(GLboolean, GLboolean, GLboolean, GLboolean))gb_symbol(renderer->gles_library, "glColorMask");
    renderer->gl.flush = (void (*)(void))gb_symbol(renderer->gles_library, "glFlush");

    renderer->present_egl.create_image = (PFNEGLCREATEIMAGEKHRPROC)gb_egl_symbol(renderer, "eglCreateImageKHR");
    renderer->present_egl.destroy_image = (PFNEGLDESTROYIMAGEKHRPROC)gb_egl_symbol(renderer, "eglDestroyImageKHR");
    renderer->present_egl.create_sync = (PFNEGLCREATESYNCKHRPROC)gb_egl_symbol(renderer, "eglCreateSyncKHR");
    renderer->present_egl.destroy_sync = (PFNEGLDESTROYSYNCKHRPROC)gb_egl_symbol(renderer, "eglDestroySyncKHR");
    renderer->present_egl.client_wait_sync =
        (PFNEGLCLIENTWAITSYNCKHRPROC)gb_egl_symbol(renderer, "eglClientWaitSyncKHR");
    renderer->present_egl.get_current_context =
        (PFNEGLGETCURRENTCONTEXTPROC)gb_egl_symbol(renderer, "eglGetCurrentContext");
    renderer->present_egl.get_current_surface =
        (PFNEGLGETCURRENTSURFACEPROC)gb_egl_symbol(renderer, "eglGetCurrentSurface");

    renderer->present_ready = renderer->gl.bind_framebuffer != NULL
        && renderer->gl.gen_framebuffers != NULL
        && renderer->gl.delete_framebuffers != NULL
        && renderer->gl.framebuffer_texture_2d != NULL
        && renderer->gl.check_framebuffer_status != NULL
        && renderer->gl.blit_framebuffer != NULL
        && renderer->gl.gen_textures != NULL
        && renderer->gl.delete_textures != NULL
        && renderer->gl.bind_texture != NULL
        && renderer->gl.egl_image_target_texture_2d != NULL
        && renderer->gl.get_integerv != NULL
        && renderer->gl.get_booleanv != NULL
        && renderer->gl.enable != NULL
        && renderer->gl.disable != NULL
        && renderer->gl.color_mask != NULL
        && renderer->gl.flush != NULL
        && renderer->present_egl.create_image != NULL
        && renderer->present_egl.destroy_image != NULL
        && renderer->present_egl.create_sync != NULL
        && renderer->present_egl.destroy_sync != NULL
        && renderer->present_egl.client_wait_sync != NULL
        && renderer->present_egl.get_current_context != NULL
        && renderer->present_egl.get_current_surface != NULL
        && renderer->virgl.borrow_texture_for_scanout != NULL;
}

/* Saves the caller's EGL state and makes the root context current. It returns false when that fails. */
static bool gb_present_enter_root(gb_renderer *renderer, struct gb_present_saved_state *saved) {
    saved->context = renderer->present_egl.get_current_context();
    saved->draw = renderer->present_egl.get_current_surface(EGL_DRAW);
    saved->read = renderer->present_egl.get_current_surface(EGL_READ);
    if (saved->context == renderer->root_context) {
        return true;
    }
    return renderer->egl.make_current(
        renderer->display,
        renderer->surface,
        renderer->surface,
        renderer->root_context
    ) == EGL_TRUE;
}

/* Restores the EGL state that `gb_present_enter_root` saved. */
static void gb_present_leave_root(gb_renderer *renderer, const struct gb_present_saved_state *saved) {
    if (saved->context == renderer->root_context) {
        return;
    }
    (void)renderer->egl.make_current(renderer->display, saved->draw, saved->read, saved->context);
}

/* Releases the GL, EGL, and Metal objects of a target. The root context must be current. */
static void gb_present_release_objects(gb_renderer *renderer, gb_present_target *target) {
    if (target->framebuffer != 0) {
        renderer->gl.delete_framebuffers(1, &target->framebuffer);
        target->framebuffer = 0;
    }
    if (target->texture != 0) {
        renderer->gl.delete_textures(1, &target->texture);
        target->texture = 0;
    }
    if (target->image != EGL_NO_IMAGE_KHR) {
        (void)renderer->present_egl.destroy_image(renderer->display, target->image);
        target->image = EGL_NO_IMAGE_KHR;
    }
    if (target->metal_texture != NULL) {
        (void)CFBridgingRelease(target->metal_texture);
        target->metal_texture = NULL;
    }
}

int gb_present_target_create(
    gb_renderer *renderer,
    void *iosurface,
    uint32_t width,
    uint32_t height,
    gb_present_target **out
) {
    if (renderer == NULL || iosurface == NULL || out == NULL || width == 0 || height == 0) {
        return GB_E_INVALID_ARGUMENT;
    }
    *out = NULL;
    if (!gb_is_render_thread(renderer)) {
        return GB_E_WRONG_THREAD;
    }
    if (!renderer->present_ready || renderer->metal_device == NULL) {
        return GB_E_PRESENT_OPERATION;
    }

    struct gb_present_saved_state saved;
    if (!gb_present_enter_root(renderer, &saved)) {
        return GB_E_PRESENT_OPERATION;
    }
    gb_present_target *target = calloc(1, sizeof(*target));
    if (target == NULL) {
        gb_present_leave_root(renderer, &saved);
        return GB_E_PRESENT_OPERATION;
    }
    target->image = EGL_NO_IMAGE_KHR;
    target->width = width;
    target->height = height;

    GLint previous_draw = 0;
    GLint previous_texture = 0;
    renderer->gl.get_integerv(GL_DRAW_FRAMEBUFFER_BINDING, &previous_draw);
    renderer->gl.get_integerv(GL_TEXTURE_BINDING_2D, &previous_texture);

    int status = GB_OK;
    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)renderer->metal_device;
        MTLTextureDescriptor *descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:width
                                                              height:height
                                                           mipmapped:NO];
        descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> texture =
            [device newTextureWithDescriptor:descriptor
                                   iosurface:(IOSurfaceRef)iosurface
                                       plane:0];
        if (texture == nil) {
            status = GB_E_PRESENT_OPERATION;
        } else {
            target->metal_texture = (__bridge_retained void *)texture;
        }
    }

    if (status == GB_OK) {
        EGLint attributes[] = { EGL_NONE };
        target->image = renderer->present_egl.create_image(
            renderer->display,
            EGL_NO_CONTEXT,
            EGL_METAL_TEXTURE_ANGLE,
            (EGLClientBuffer)target->metal_texture,
            attributes
        );
        if (target->image == EGL_NO_IMAGE_KHR) {
            status = GB_E_PRESENT_OPERATION;
        }
    }
    if (status == GB_OK) {
        renderer->gl.gen_textures(1, &target->texture);
        renderer->gl.bind_texture(GL_TEXTURE_2D, target->texture);
        renderer->gl.egl_image_target_texture_2d(GL_TEXTURE_2D, (GLeglImageOES)target->image);
        renderer->gl.gen_framebuffers(1, &target->framebuffer);
        renderer->gl.bind_framebuffer(GL_DRAW_FRAMEBUFFER, target->framebuffer);
        renderer->gl.framebuffer_texture_2d(
            GL_DRAW_FRAMEBUFFER,
            GL_COLOR_ATTACHMENT0,
            GL_TEXTURE_2D,
            target->texture,
            0
        );
        if (renderer->gl.check_framebuffer_status(GL_DRAW_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            status = GB_E_PRESENT_OPERATION;
        }
    }
    renderer->gl.bind_framebuffer(GL_DRAW_FRAMEBUFFER, (GLuint)previous_draw);
    renderer->gl.bind_texture(GL_TEXTURE_2D, (GLuint)previous_texture);

    if (status != GB_OK) {
        gb_present_release_objects(renderer, target);
        free(target);
    } else {
        *out = target;
    }
    gb_present_leave_root(renderer, &saved);
    return status;
}

void gb_present_target_destroy(gb_renderer *renderer, gb_present_target *target) {
    if (renderer == NULL || target == NULL) {
        return;
    }
    if (!gb_is_render_thread(renderer) || !renderer->present_ready) {
        return;
    }
    struct gb_present_saved_state saved;
    if (gb_present_enter_root(renderer, &saved)) {
        gb_present_release_objects(renderer, target);
        gb_present_leave_root(renderer, &saved);
    }
    free(target);
}

int gb_present_blit(
    gb_renderer *renderer,
    uint32_t res_id,
    uint32_t x,
    uint32_t y,
    uint32_t width,
    uint32_t height,
    gb_present_target *target,
    void **out_sync
) {
    if (renderer == NULL || target == NULL || out_sync == NULL || width == 0 || height == 0) {
        return GB_E_INVALID_ARGUMENT;
    }
    *out_sync = NULL;
    if (!gb_is_render_thread(renderer)) {
        return GB_E_WRONG_THREAD;
    }
    if (!renderer->present_ready) {
        return GB_E_PRESENT_OPERATION;
    }

    struct gb_present_saved_state saved;
    if (!gb_present_enter_root(renderer, &saved)) {
        return GB_E_PRESENT_OPERATION;
    }

    int status = GB_OK;
    GLint previous_texture = 0;
    renderer->gl.get_integerv(GL_TEXTURE_BINDING_2D, &previous_texture);
    struct virgl_renderer_resource_info_ext info;
    memset(&info, 0, sizeof(info));
    // The borrow binds the resource's GL texture and fixes its swizzle (virglrenderer, graphics.md §6.2).
    if (renderer->virgl.borrow_texture_for_scanout((int)res_id, &info) != 0 || info.base.tex_id == 0) {
        status = GB_E_RESOURCE_OPERATION;
    } else if (x > info.base.width || width > info.base.width - x
        || y > info.base.height || height > info.base.height - y) {
        status = GB_E_INVALID_ARGUMENT;
    }

    if (status == GB_OK) {
        GLint previous_read = 0;
        GLint previous_draw = 0;
        GLboolean previous_scissor = GL_FALSE;
        GLboolean previous_mask[4] = { GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE };
        if (renderer->present_source_framebuffer == 0) {
            renderer->gl.gen_framebuffers(1, &renderer->present_source_framebuffer);
        }
        renderer->gl.get_integerv(GL_READ_FRAMEBUFFER_BINDING, &previous_read);
        renderer->gl.get_integerv(GL_DRAW_FRAMEBUFFER_BINDING, &previous_draw);
        renderer->gl.get_booleanv(GL_SCISSOR_TEST, &previous_scissor);
        renderer->gl.get_booleanv(GL_COLOR_WRITEMASK, previous_mask);

        renderer->gl.bind_framebuffer(GL_READ_FRAMEBUFFER, renderer->present_source_framebuffer);
        renderer->gl.framebuffer_texture_2d(
            GL_READ_FRAMEBUFFER,
            GL_COLOR_ATTACHMENT0,
            GL_TEXTURE_2D,
            info.base.tex_id,
            0
        );
        renderer->gl.bind_framebuffer(GL_DRAW_FRAMEBUFFER, target->framebuffer);
        renderer->gl.disable(GL_SCISSOR_TEST);
        renderer->gl.color_mask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        // The scaling blit is the only pixel work of the present path. Nothing reads the pixels back.
        renderer->gl.blit_framebuffer(
            (GLint)x,
            (GLint)y,
            (GLint)(x + width),
            (GLint)(y + height),
            0,
            0,
            (GLint)target->width,
            (GLint)target->height,
            GL_COLOR_BUFFER_BIT,
            GL_NEAREST
        );
        renderer->gl.flush();
        EGLSyncKHR sync = renderer->present_egl.create_sync(renderer->display, EGL_SYNC_FENCE_KHR, NULL);
        if (sync == EGL_NO_SYNC_KHR) {
            status = GB_E_PRESENT_OPERATION;
        } else {
            *out_sync = sync;
        }

        renderer->gl.bind_framebuffer(GL_READ_FRAMEBUFFER, (GLuint)previous_read);
        renderer->gl.bind_framebuffer(GL_DRAW_FRAMEBUFFER, (GLuint)previous_draw);
        if (previous_scissor) {
            renderer->gl.enable(GL_SCISSOR_TEST);
        }
        renderer->gl.color_mask(previous_mask[0], previous_mask[1], previous_mask[2], previous_mask[3]);
    }
    renderer->gl.bind_texture(GL_TEXTURE_2D, (GLuint)previous_texture);
    gb_present_leave_root(renderer, &saved);
    return status;
}

int gb_sync_wait(gb_renderer *renderer, void *sync, uint64_t timeout_ns) {
    if (renderer == NULL || sync == NULL || !renderer->present_ready) {
        return GB_E_INVALID_ARGUMENT;
    }
    if (!gb_is_render_thread(renderer)) {
        return GB_E_WRONG_THREAD;
    }
    // ANGLE validates a fence wait against the current context (EGL_BAD_CONTEXT otherwise), so the root context
    // is current for the wait. A zero timeout is a poll, which the render thread runs between requests (graphics.md §6.2).
    struct gb_present_saved_state saved;
    if (!gb_present_enter_root(renderer, &saved)) {
        return GB_E_PRESENT_OPERATION;
    }
    EGLint result = renderer->present_egl.client_wait_sync(
        renderer->display,
        (EGLSyncKHR)sync,
        0,
        (EGLTimeKHR)timeout_ns
    );
    gb_present_leave_root(renderer, &saved);
    if (result == EGL_CONDITION_SATISFIED_KHR) {
        return GB_OK;
    }
    if (result == EGL_TIMEOUT_EXPIRED_KHR) {
        return GB_SYNC_TIMEOUT;
    }
    return GB_E_PRESENT_OPERATION;
}

void gb_sync_destroy(gb_renderer *renderer, void *sync) {
    if (renderer == NULL || sync == NULL || !renderer->present_ready || !gb_is_render_thread(renderer)) {
        return;
    }
    struct gb_present_saved_state saved;
    if (!gb_present_enter_root(renderer, &saved)) {
        return;
    }
    (void)renderer->present_egl.destroy_sync(renderer->display, (EGLSyncKHR)sync);
    gb_present_leave_root(renderer, &saved);
}

int gb_renderer_create(const gb_callbacks *callbacks, void *user, gb_renderer **out) {
    if (out == NULL) {
        return GB_E_INVALID_ARGUMENT;
    }
    *out = NULL;

    gb_renderer *renderer = calloc(1, sizeof(*renderer));
    if (renderer == NULL) {
        return GB_E_VIRGL_INITIALIZATION;
    }
    renderer->display = EGL_NO_DISPLAY;
    renderer->surface = EGL_NO_SURFACE;
    renderer->root_context = EGL_NO_CONTEXT;
    renderer->render_thread = pthread_self();
    if (callbacks != NULL) {
        renderer->callbacks = *callbacks;
    }
    renderer->user = user;

    pthread_mutex_lock(&gb_renderer_lock);
    if (gb_active_renderer != NULL) {
        pthread_mutex_unlock(&gb_renderer_lock);
        gb_emit_log(
            renderer,
            GB_LOG_ERROR,
            gb_status_description(GB_E_RENDERER_ALREADY_EXISTS)
        );
        free(renderer);
        return GB_E_RENDERER_ALREADY_EXISTS;
    }
    gb_active_renderer = renderer;
    renderer->owns_process_slot = true;
    pthread_mutex_unlock(&gb_renderer_lock);

    NSString *runtime_directory = gb_runtime_directory();
    if (runtime_directory == nil || !gb_is_directory(runtime_directory)) {
        gb_emit_log(renderer, GB_LOG_ERROR, gb_status_description(GB_E_RUNTIME_DIRECTORY_MISSING));
        gb_release_renderer(renderer);
        return GB_E_RUNTIME_DIRECTORY_MISSING;
    }

    renderer->epoxy_library = gb_open_library(renderer, runtime_directory, gb_runtime_libraries[0]);
    if (renderer->epoxy_library == NULL) {
        gb_release_renderer(renderer);
        return GB_E_LIBRARY_MISSING_EPOXY;
    }
    renderer->egl_library = gb_open_library(renderer, runtime_directory, gb_runtime_libraries[1]);
    if (renderer->egl_library == NULL) {
        gb_release_renderer(renderer);
        return GB_E_LIBRARY_MISSING_EGL;
    }
    renderer->gles_library = gb_open_library(renderer, runtime_directory, gb_runtime_libraries[2]);
    if (renderer->gles_library == NULL) {
        gb_release_renderer(renderer);
        return GB_E_LIBRARY_MISSING_GLES;
    }
    renderer->virgl_library = gb_open_library(renderer, runtime_directory, gb_runtime_libraries[3]);
    if (renderer->virgl_library == NULL) {
        gb_release_renderer(renderer);
        return GB_E_LIBRARY_MISSING_VIRGL;
    }

    if (!gb_load_virgl_api(renderer)) {
        gb_emit_log(renderer, GB_LOG_ERROR, "virglrenderer exports an incompatible API.");
        gb_release_renderer(renderer);
        return GB_E_LIBRARY_MISSING_VIRGL;
    }

    int status = gb_initialize_egl(renderer);
    if (status != GB_OK) {
        gb_emit_log(renderer, GB_LOG_ERROR, gb_status_description(status));
        gb_release_renderer(renderer);
        return status;
    }
    // The present entry points are optional for the 2D and 3D paths, so a missing one only disables presentation.
    gb_load_present_api(renderer);

    renderer->virgl_callbacks.version = VIRGL_RENDERER_CALLBACKS_VERSION;
    renderer->virgl_callbacks.write_fence = gb_virgl_write_fence;
    renderer->virgl_callbacks.create_gl_context = gb_create_gl_context;
    renderer->virgl_callbacks.destroy_gl_context = gb_destroy_gl_context;
    renderer->virgl_callbacks.make_current = gb_make_current;
    renderer->virgl_callbacks.get_egl_display = gb_get_egl_display;

    renderer->virgl.set_log_callback(gb_virgl_log, renderer, NULL);
    renderer->log_callback_registered = true;

    int result = renderer->virgl.renderer_init(renderer, 0, &renderer->virgl_callbacks);
    if (result != 0) {
        gb_emit_log(renderer, GB_LOG_ERROR, gb_status_description(GB_E_VIRGL_INITIALIZATION));
        gb_release_renderer(renderer);
        return GB_E_VIRGL_INITIALIZATION;
    }

    renderer->virgl_initialized = true;
    *out = renderer;
    return GB_OK;
}

int gb_renderer_destroy(gb_renderer *renderer) {
    if (renderer == NULL) {
        return GB_E_INVALID_ARGUMENT;
    }
    if (!gb_is_render_thread(renderer)) {
        return GB_E_WRONG_THREAD;
    }
    gb_release_renderer(renderer);
    return GB_OK;
}

int gb_renderer_reset(gb_renderer *renderer) {
    if (renderer == NULL || !renderer->virgl_initialized) {
        return GB_E_INVALID_ARGUMENT;
    }
    if (!gb_is_render_thread(renderer)) {
        return GB_E_WRONG_THREAD;
    }
    renderer->virgl.renderer_reset();
    gb_free_backing_records(renderer);
    return GB_OK;
}

int gb_renderer_metal_device(gb_renderer *renderer, void **out) {
    if (out != NULL) {
        *out = NULL;
    }
    if (renderer == NULL || !renderer->virgl_initialized || out == NULL) {
        return GB_E_INVALID_ARGUMENT;
    }
    if (!gb_is_render_thread(renderer)) {
        return GB_E_WRONG_THREAD;
    }
    if (renderer->metal_device == NULL) {
        return GB_E_METAL_DEVICE;
    }
    *out = renderer->metal_device;
    return GB_OK;
}

int gb_capset_info(
    gb_renderer *renderer,
    uint32_t capset_id,
    uint32_t *max_version,
    uint32_t *max_size_bytes
) {
    if (max_version != NULL) {
        *max_version = 0;
    }
    if (max_size_bytes != NULL) {
        *max_size_bytes = 0;
    }
    if (renderer == NULL || !renderer->virgl_initialized
        || max_version == NULL || max_size_bytes == NULL) {
        return GB_E_INVALID_ARGUMENT;
    }
    if (!gb_is_render_thread(renderer)) {
        return GB_E_WRONG_THREAD;
    }

    renderer->virgl.renderer_get_cap_set(capset_id, max_version, max_size_bytes);
    return *max_version > 0 && *max_size_bytes > 0 ? GB_OK : GB_E_CAPSET_UNAVAILABLE;
}

int gb_capset_fill(
    gb_renderer *renderer,
    uint32_t capset_id,
    uint32_t version,
    void *out,
    size_t out_size_bytes
) {
    if (renderer == NULL || !renderer->virgl_initialized || out == NULL || version == 0) {
        return GB_E_INVALID_ARGUMENT;
    }
    if (!gb_is_render_thread(renderer)) {
        return GB_E_WRONG_THREAD;
    }

    uint32_t max_version = 0;
    uint32_t max_size_bytes = 0;
    renderer->virgl.renderer_get_cap_set(capset_id, &max_version, &max_size_bytes);
    if (max_version == 0 || max_size_bytes == 0 || version > max_version) {
        return GB_E_CAPSET_UNAVAILABLE;
    }
    if (out_size_bytes < max_size_bytes) {
        return GB_E_BUFFER_TOO_SMALL;
    }

    renderer->virgl.renderer_fill_caps(capset_id, version, out);
    return GB_OK;
}

int gb_ctx_create(gb_renderer *renderer, uint32_t ctx_id, const char *name) {
    if (renderer == NULL || !renderer->virgl_initialized || name == NULL) {
        return GB_E_INVALID_ARGUMENT;
    }
    if (!gb_is_render_thread(renderer)) {
        return GB_E_WRONG_THREAD;
    }
    size_t length = strlen(name);
    if (length > UINT32_MAX) {
        return GB_E_INVALID_ARGUMENT;
    }

    return renderer->virgl.renderer_context_create(ctx_id, (uint32_t)length, name) == 0
        ? GB_OK
        : GB_E_CONTEXT_CREATION;
}

int gb_ctx_destroy(gb_renderer *renderer, uint32_t ctx_id) {
    if (renderer == NULL || !renderer->virgl_initialized) {
        return GB_E_INVALID_ARGUMENT;
    }
    if (!gb_is_render_thread(renderer)) {
        return GB_E_WRONG_THREAD;
    }
    renderer->virgl.renderer_context_destroy(ctx_id);
    return GB_OK;
}

static bool gb_renderer_is_ready_on_this_thread(gb_renderer *renderer, int *status) {
    if (renderer == NULL || !renderer->virgl_initialized) {
        *status = GB_E_INVALID_ARGUMENT;
        return false;
    }
    if (!gb_is_render_thread(renderer)) {
        *status = GB_E_WRONG_THREAD;
        return false;
    }
    return true;
}

static struct virgl_box gb_box_from_args(const gb_transfer_args *args) {
    struct virgl_box box = {args->x, args->y, args->z, args->width, args->height, args->depth};
    return box;
}

int gb_ctx_attach_resource(gb_renderer *renderer, uint32_t ctx_id, uint32_t res_id) {
    int status = GB_OK;
    if (!gb_renderer_is_ready_on_this_thread(renderer, &status)) {
        return status;
    }
    if (ctx_id > INT32_MAX || res_id > INT32_MAX) {
        return GB_E_INVALID_ARGUMENT;
    }
    renderer->virgl.ctx_attach_resource((int)ctx_id, (int)res_id);
    return GB_OK;
}

void gb_ctx_detach_resource(gb_renderer *renderer, uint32_t ctx_id, uint32_t res_id) {
    int status = GB_OK;
    if (!gb_renderer_is_ready_on_this_thread(renderer, &status)) {
        return;
    }
    if (ctx_id > INT32_MAX || res_id > INT32_MAX) {
        return;
    }
    renderer->virgl.ctx_detach_resource((int)ctx_id, (int)res_id);
}

int gb_submit(gb_renderer *renderer, uint32_t ctx_id, const void *commands, size_t size_bytes) {
    return gb_submit_with_result(renderer, ctx_id, commands, size_bytes, NULL);
}

int gb_submit_with_result(
    gb_renderer *renderer,
    uint32_t ctx_id,
    const void *commands,
    size_t size_bytes,
    int *virgl_result
) {
    if (virgl_result != NULL) {
        *virgl_result = INT32_MIN;
    }
    int status = GB_OK;
    if (!gb_renderer_is_ready_on_this_thread(renderer, &status)) {
        return status;
    }
    if (commands == NULL || size_bytes == 0 || size_bytes % sizeof(uint32_t) != 0
        || size_bytes > INT32_MAX) {
        return GB_E_INVALID_ARGUMENT;
    }

    /* virglrenderer rejects buffers that are not 4-byte aligned, so copy those. */
    void *aligned = NULL;
    void *stream = (void *)commands;
    if (((uintptr_t)commands & 3) != 0) {
        aligned = malloc(size_bytes);
        if (aligned == NULL) {
            return GB_E_SUBMIT_OPERATION;
        }
        memcpy(aligned, commands, size_bytes);
        stream = aligned;
    }
    int result = renderer->virgl.submit_cmd(stream, (int)ctx_id, (int)(size_bytes / sizeof(uint32_t)));
    free(aligned);
    if (virgl_result != NULL) {
        *virgl_result = result;
    }
    return result == 0 ? GB_OK : GB_E_SUBMIT_OPERATION;
}

int gb_resource_create(gb_renderer *renderer, const gb_resource_args *args) {
    int status = GB_OK;
    if (!gb_renderer_is_ready_on_this_thread(renderer, &status)) {
        return status;
    }
    if (args == NULL || args->resource_id == 0) {
        return GB_E_INVALID_ARGUMENT;
    }
    struct virgl_renderer_resource_create_args create = {
        .handle = args->resource_id,
        .target = args->target,
        .format = args->format,
        .bind = args->bind,
        .width = args->width,
        .height = args->height,
        .depth = args->depth,
        .array_size = args->array_size,
        .last_level = args->last_level,
        .nr_samples = args->sample_count,
        .flags = args->flags,
    };
    int result = renderer->virgl.resource_create(&create, NULL, 0);
    return result == 0 ? GB_OK : GB_E_RESOURCE_OPERATION;
}

void gb_resource_unref(gb_renderer *renderer, uint32_t res_id) {
    int status = GB_OK;
    if (!gb_renderer_is_ready_on_this_thread(renderer, &status)) {
        return;
    }
    gb_detach_backing_record(renderer, res_id);
    renderer->virgl.resource_unref(res_id);
}

int gb_resource_attach_backing(
    gb_renderer *renderer,
    uint32_t res_id,
    const gb_backing_range *ranges,
    size_t count
) {
    int status = GB_OK;
    if (!gb_renderer_is_ready_on_this_thread(renderer, &status)) {
        return status;
    }
    if (res_id == 0 || res_id > INT32_MAX || ranges == NULL || count == 0 || count > INT32_MAX) {
        return GB_E_INVALID_ARGUMENT;
    }
    for (size_t i = 0; i < count; i++) {
        if (ranges[i].base == NULL || ranges[i].length == 0) {
            return GB_E_INVALID_ARGUMENT;
        }
    }
    for (struct gb_backing_record *record = renderer->backings; record != NULL; record = record->next) {
        if (record->res_id == res_id) {
            return GB_E_RESOURCE_OPERATION;
        }
    }

    struct gb_backing_record *record = calloc(1, sizeof(*record));
    struct iovec *iov = calloc(count, sizeof(*iov));
    if (record == NULL || iov == NULL) {
        free(record);
        free(iov);
        return GB_E_RESOURCE_OPERATION;
    }
    for (size_t i = 0; i < count; i++) {
        iov[i].iov_base = ranges[i].base;
        iov[i].iov_len = ranges[i].length;
    }
    if (renderer->virgl.resource_attach_iov((int)res_id, iov, (int)count) != 0) {
        free(record);
        free(iov);
        return GB_E_RESOURCE_OPERATION;
    }
    record->res_id = res_id;
    record->iov = iov;
    record->next = renderer->backings;
    renderer->backings = record;
    return GB_OK;
}

void gb_resource_detach_backing(gb_renderer *renderer, uint32_t res_id) {
    int status = GB_OK;
    if (!gb_renderer_is_ready_on_this_thread(renderer, &status)) {
        return;
    }
    if (res_id == 0 || res_id > INT32_MAX) {
        return;
    }
    gb_detach_backing_record(renderer, res_id);
}

int gb_transfer_write(
    gb_renderer *renderer,
    const gb_transfer_args *args,
    void *buffer,
    size_t buffer_bytes
) {
    int status = GB_OK;
    if (!gb_renderer_is_ready_on_this_thread(renderer, &status)) {
        return status;
    }
    if (args == NULL || buffer == NULL || buffer_bytes == 0) {
        return GB_E_INVALID_ARGUMENT;
    }
    struct virgl_box box = gb_box_from_args(args);
    struct iovec iov = {.iov_base = buffer, .iov_len = buffer_bytes};
    int result = renderer->virgl.transfer_write_iov(
        args->resource_id, args->ctx_id, (int)args->level, args->stride, args->layer_stride,
        &box, 0, &iov, 1
    );
    return result == 0 ? GB_OK : GB_E_TRANSFER_OPERATION;
}

int gb_transfer_read(
    gb_renderer *renderer,
    const gb_transfer_args *args,
    void *buffer,
    size_t buffer_bytes
) {
    int status = GB_OK;
    if (!gb_renderer_is_ready_on_this_thread(renderer, &status)) {
        return status;
    }
    if (args == NULL || buffer == NULL || buffer_bytes == 0) {
        return GB_E_INVALID_ARGUMENT;
    }
    struct virgl_box box = gb_box_from_args(args);
    struct iovec iov = {.iov_base = buffer, .iov_len = buffer_bytes};
    int result = renderer->virgl.transfer_read_iov(
        args->resource_id, args->ctx_id, args->level, args->stride, args->layer_stride,
        &box, 0, &iov, 1
    );
    return result == 0 ? GB_OK : GB_E_TRANSFER_OPERATION;
}

int gb_create_fence(gb_renderer *renderer, uint32_t fence_id, uint32_t ctx_id) {
    int status = GB_OK;
    if (!gb_renderer_is_ready_on_this_thread(renderer, &status)) {
        return status;
    }
    /* virglrenderer takes the fence as an int and casts it back to uint32_t, so the bit pattern is passed unchanged. */
    int32_t bits = 0;
    memcpy(&bits, &fence_id, sizeof bits);
    int result = renderer->virgl.create_fence((int)bits, ctx_id);
    return result == 0 ? GB_OK : GB_E_FENCE_OPERATION;
}

void gb_poll(gb_renderer *renderer) {
    int status = GB_OK;
    if (!gb_renderer_is_ready_on_this_thread(renderer, &status)) {
        return;
    }
    renderer->virgl.poll();
}
