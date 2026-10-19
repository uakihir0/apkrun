package io.apkrun.fixture.hellowebview

import android.app.Activity
import android.os.Bundle
import android.util.Log
import android.webkit.WebView
import android.webkit.WebViewClient

/**
 * Displays the bundled local page and reports `APKRUN-FIXTURE: loaded` after WebView both finishes loading and makes
 * the page visible. The page is local and script-free so the event does not depend on network or remote content.
 */
class MainActivity : Activity() {
    private var pageCommitted = false
    private var pageFinished = false
    private var loadedLogged = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val webView =
            WebView(this).apply {
                settings.javaScriptEnabled = false
                settings.domStorageEnabled = false
                webViewClient =
                    object : WebViewClient() {
                        override fun onPageCommitVisible(view: WebView, url: String) {
                            super.onPageCommitVisible(view, url)
                            if (url == PAGE_URL) {
                                pageCommitted = true
                                logLoadedIfReady()
                            }
                        }

                        override fun onPageFinished(view: WebView, url: String) {
                            super.onPageFinished(view, url)
                            if (url == PAGE_URL) {
                                pageFinished = true
                                logLoadedIfReady()
                            }
                        }
                    }
            }
        setContentView(webView)
        webView.loadUrl(PAGE_URL)
    }

    private fun logLoadedIfReady() {
        if (!loadedLogged && pageCommitted && pageFinished) {
            loadedLogged = true
            Log.i(LOG_TAG, "loaded")
        }
    }

    private companion object {
        const val LOG_TAG = "APKRUN-FIXTURE"
        const val PAGE_URL = "file:///android_asset/index.html"
    }
}
