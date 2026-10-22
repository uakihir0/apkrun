package io.apkrun.guest.health

import android.app.Activity
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View

/** A short visual probe for Android display, composition, and host frame delivery. */
class HealthCheckActivity : Activity() {
    private val finishHandler = Handler(Looper.getMainLooper())
    private val finishProbe = Runnable { finish() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(HealthPatternView())
        finishHandler.postDelayed(finishProbe, FINISH_AFTER_MILLIS)
    }

    override fun onDestroy() {
        finishHandler.removeCallbacks(finishProbe)
        super.onDestroy()
    }

    private inner class HealthPatternView : View(this@HealthCheckActivity) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        private var loggedDraw = false

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val halfWidth = width / 2f
            val halfHeight = height / 2f
            canvas.drawColor(Color.BLACK)
            drawQuadrant(canvas, Color.rgb(239, 83, 80), 0f, 0f, halfWidth, halfHeight)
            drawQuadrant(
                canvas,
                Color.rgb(102, 187, 106),
                halfWidth,
                0f,
                width.toFloat(),
                halfHeight,
            )
            drawQuadrant(
                canvas,
                Color.rgb(66, 165, 245),
                0f,
                halfHeight,
                halfWidth,
                height.toFloat(),
            )
            drawQuadrant(
                canvas,
                Color.rgb(255, 202, 40),
                halfWidth,
                halfHeight,
                width.toFloat(),
                height.toFloat(),
            )
            if (!loggedDraw) {
                loggedDraw = true
                Log.i(TAG, DRAWN_MARKER)
            }
        }

        private fun drawQuadrant(
            canvas: Canvas,
            color: Int,
            left: Float,
            top: Float,
            right: Float,
            bottom: Float,
        ) {
            paint.color = color
            canvas.drawRect(left, top, right, bottom, paint)
        }
    }

    private companion object {
        const val FINISH_AFTER_MILLIS = 2_000L
        const val TAG = "ApkRunGuest"
        const val DRAWN_MARKER = "APKRUN-HEALTH: drawn"
    }
}
