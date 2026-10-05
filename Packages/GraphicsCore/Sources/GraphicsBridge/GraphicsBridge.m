#import <Foundation/Foundation.h>

#include "GraphicsBridge.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <virgl/virglrenderer.h>

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

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

    return renderer->virgl.renderer_init != NULL
        && renderer->virgl.renderer_cleanup != NULL
        && renderer->virgl.renderer_reset != NULL
        && renderer->virgl.renderer_get_cap_set != NULL
        && renderer->virgl.renderer_fill_caps != NULL
        && renderer->virgl.renderer_context_create != NULL
        && renderer->virgl.renderer_context_destroy != NULL
        && renderer->virgl.set_log_callback != NULL;
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

    EGLContext shared = parameters->shared ? renderer->root_context : EGL_NO_CONTEXT;
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

static void gb_release_renderer(gb_renderer *renderer) {
    if (renderer == NULL) {
        return;
    }

    if (renderer->virgl_initialized && renderer->virgl.renderer_cleanup != NULL) {
        renderer->virgl.renderer_cleanup(renderer);
        renderer->virgl_initialized = false;
    }
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
        default:
            return "unknown graphics bridge failure";
    }
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
