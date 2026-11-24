package io.apkrun.fixture.helloaudio

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Bundle
import android.util.Log
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.concurrent.thread
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin

/**
 * The audio fixture of #84/#85 (test-strategy.md §4.2): plays a 1 kHz tone, a sweep, and a click
 * track (one click per second), and records 5 s while showing the level. Each playback logs
 * `play <name>` at start; a finished recording logs `recorded <frames> <peak>`.
 */
class MainActivity : Activity() {
    private val output = TextView(this)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        layout.addView(output)
        layout.addView(button("Play 1 kHz tone") { play("tone") { tone() } })
        layout.addView(button("Play sweep") { play("sweep") { sweep() } })
        layout.addView(button("Play click track") { play("click") { clickTrack() } })
        layout.addView(button("Record 5 s") { record() })
        setContentView(layout)
    }

    private fun button(label: String, action: () -> Unit): Button =
        Button(this).apply {
            text = label
            setOnClickListener { action() }
        }

    private fun show(line: String) {
        output.text = line
    }

    /** Plays [samples] on the default output at [SAMPLE_RATE], mono PCM16. */
    private fun play(name: String, samples: () -> ShortArray) {
        Log.i(TAG, "play $name")
        show("Playing $name…")
        thread(name = "helloaudio-play") {
            val pcm = samples()
            val track =
                AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build()
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setSampleRate(SAMPLE_RATE)
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                            .build()
                    )
                    .setBufferSizeInBytes(pcm.size * 2)
                    .setTransferMode(AudioTrack.MODE_STATIC)
                    .build()
            try {
                track.write(pcm, 0, pcm.size)
                track.play()
                while (track.playState == AudioTrack.PLAYSTATE_PLAYING) {
                    Thread.sleep(50)
                }
            } finally {
                track.release()
            }
            runOnUiThread { show("Done: $name") }
        }
    }

    /** Three seconds of a 1 kHz sine at half amplitude. */
    private fun tone(): ShortArray =
        ShortArray(SAMPLE_RATE * 3) { i ->
            (Short.MAX_VALUE / 2 * sin(2.0 * PI * 1000.0 * i / SAMPLE_RATE))
                .toInt()
                .toShort()
        }

    /** Three seconds sweeping 200 Hz to 2 kHz. */
    private fun sweep(): ShortArray {
        val pcm = ShortArray(SAMPLE_RATE * 3)
        var phase = 0.0
        for (i in pcm.indices) {
            val t = i.toDouble() / SAMPLE_RATE
            val hz = 200.0 + (2000.0 - 200.0) * (t / 3.0)
            phase += 2.0 * PI * hz / SAMPLE_RATE
            pcm[i] = (Short.MAX_VALUE / 2 * sin(phase)).toInt().toShort()
        }
        return pcm
    }

    /** Ten seconds of one 20 ms click per second for the loopback latency measure. */
    private fun clickTrack(): ShortArray {
        val pcm = ShortArray(SAMPLE_RATE * 10)
        val clickSamples = SAMPLE_RATE / 50
        for (second in 0 until 10) {
            val start = second * SAMPLE_RATE
            for (i in 0 until clickSamples) {
                // A decaying burst is easier to pick out of the capture than a square edge.
                pcm[start + i] =
                    (Short.MAX_VALUE * 0.8 * (1.0 - i.toDouble() / clickSamples))
                        .toInt()
                        .toShort()
            }
        }
        return pcm
    }

    private fun record() {
        if (
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
                PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_RECORD)
            return
        }
        show("Recording…")
        thread(name = "helloaudio-record") {
            val bufferSize =
                maxOf(
                    AudioRecord.getMinBufferSize(
                        SAMPLE_RATE,
                        AudioFormat.CHANNEL_IN_MONO,
                        AudioFormat.ENCODING_PCM_16BIT,
                    ),
                    SAMPLE_RATE * 2,
                )
            val recorder =
                AudioRecord(
                    MediaRecorder.AudioSource.MIC,
                    SAMPLE_RATE,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                    bufferSize,
                )
            try {
                recorder.startRecording()
                val frames = SAMPLE_RATE * 5
                val pcm = ShortArray(frames)
                var read = 0
                while (read < frames) {
                    read += recorder.read(pcm, read, frames - read).coerceAtLeast(0)
                }
                val peak = pcm.maxOf { abs(it.toInt()) }
                Log.i(TAG, "recorded $frames $peak")
                runOnUiThread { show("Recorded $frames frames, peak $peak") }
            } finally {
                recorder.stop()
                recorder.release()
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (
            requestCode == REQUEST_RECORD &&
                grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
        ) {
            record()
        } else {
            show("Microphone permission denied")
        }
    }

    private companion object {
        const val TAG = "APKRUN-FIXTURE"
        const val SAMPLE_RATE = 44100
        const val REQUEST_RECORD = 1
    }
}
