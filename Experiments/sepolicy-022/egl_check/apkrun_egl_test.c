/*
 * apkrun_egl_test: the eglInitialize check of #99. Test only, never a product binary.
 *
 * It calls eglGetDisplay(EGL_DEFAULT_DISPLAY) and eglInitialize, logs one line with the fixed tag
 * APKRUN-TEST to logcat, and exits 0 only when eglInitialize succeeds. The init rc
 * (apkrun_egl_test.rc) runs it once on sys.boot_completed (test variant; no command-line gate, IR-993).
 */

#include <EGL/egl.h>
#include <android/log.h>

#define TAG "APKRUN-TEST"

static const char *text(const char *value)
{
	return value ? value : "(null)";
}

int main(void)
{
	EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	EGLint major = 0;
	EGLint minor = 0;

	if (display == EGL_NO_DISPLAY) {
		__android_log_print(ANDROID_LOG_ERROR, TAG,
				    "egl failed: eglGetDisplay returned EGL_NO_DISPLAY, eglGetError 0x%x",
				    (unsigned)eglGetError());
		return 1;
	}
	if (eglInitialize(display, &major, &minor) != EGL_TRUE) {
		__android_log_print(ANDROID_LOG_ERROR, TAG,
				    "egl failed: eglInitialize returned EGL_FALSE, eglGetError 0x%x",
				    (unsigned)eglGetError());
		return 1;
	}
	__android_log_print(ANDROID_LOG_INFO, TAG,
			    "egl ok: eglInitialize %d.%d, EGL_VENDOR %s, EGL_VERSION %s",
			    (int)major, (int)minor,
			    text(eglQueryString(display, EGL_VENDOR)),
			    text(eglQueryString(display, EGL_VERSION)));
	eglTerminate(display);
	return 0;
}
