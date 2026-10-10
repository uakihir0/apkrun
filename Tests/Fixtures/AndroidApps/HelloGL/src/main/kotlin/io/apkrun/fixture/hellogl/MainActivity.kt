package io.apkrun.fixture.hellogl

import android.app.Activity
import android.opengl.GLES30
import android.opengl.GLSurfaceView
import android.os.Bundle
import android.util.Log
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

/**
 * The only Activity of HelloGL. It draws with GLES 3.0 and logs two events, which the T2 checks read (test-strategy.md
 * §4.2): `APKRUN-FIXTURE: renderer <GL_RENDERER>` once the surface exists, and `APKRUN-FIXTURE: fps <average>` every
 * 10 seconds.
 *
 * With the intent extra [EXTRA_ALTERNATE] set to true, the screen alternates between two colours on every frame. The
 * tearing check of #023 samples the frames for that mode.
 */
class MainActivity : Activity() {
    private lateinit var glView: GLSurfaceView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val alternate = intent.getBooleanExtra(EXTRA_ALTERNATE, false)
        glView = GLSurfaceView(this)
        glView.setEGLContextClientVersion(3)
        glView.setRenderer(HelloRenderer(alternate))
        glView.renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY
        setContentView(glView)
    }

    override fun onResume() {
        super.onResume()
        glView.onResume()
    }

    override fun onPause() {
        super.onPause()
        glView.onPause()
    }

    companion object {
        /** The boolean intent extra that selects the alternating-colour mode. */
        const val EXTRA_ALTERNATE = "io.apkrun.fixture.hellogl.ALTERNATE"
    }
}

/** Clears the screen each frame, and reports the renderer and the frame rate. Runs on the GL thread. */
private class HelloRenderer(private val alternate: Boolean) : GLSurfaceView.Renderer {
    private var framesInWindow = 0L
    private var windowStartNanos = 0L

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        Log.i(TAG, "APKRUN-FIXTURE: renderer ${GLES30.glGetString(GLES30.GL_RENDERER)}")
        windowStartNanos = System.nanoTime()
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        GLES30.glViewport(0, 0, width, height)
    }

    override fun onDrawFrame(gl: GL10?) {
        val now = System.nanoTime()
        if (alternate) {
            if (framesInWindow % 2 == 0L) clear(1f, 0f, 0f) else clear(0f, 0f, 1f)
        } else {
            val phase = (now % FOUR_SECONDS_NANOS).toFloat() / FOUR_SECONDS_NANOS
            clear(phase, 0.5f, 1f - phase)
        }
        framesInWindow++
        val elapsed = now - windowStartNanos
        if (elapsed >= TEN_SECONDS_NANOS) {
            Log.i(TAG, "APKRUN-FIXTURE: fps ${"%.1f".format(framesInWindow * 1e9 / elapsed)}")
            framesInWindow = 0
            windowStartNanos = now
        }
    }

    private fun clear(red: Float, green: Float, blue: Float) {
        GLES30.glClearColor(red, green, blue, 1f)
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)
    }

    private companion object {
        const val TAG = "HelloGL"
        const val FOUR_SECONDS_NANOS = 4_000_000_000L
        const val TEN_SECONDS_NANOS = 10_000_000_000L
    }
}
