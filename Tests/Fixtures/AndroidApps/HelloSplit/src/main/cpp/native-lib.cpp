#include <jni.h>

extern "C" JNIEXPORT jstring JNICALL
Java_io_apkrun_fixture_hellosplit_NativeProbe_message(JNIEnv* env, jobject) {
    return env->NewStringUTF("native ok");
}
