package io.apkrun.fixture.hellotext

import android.app.Activity
import android.os.Bundle
import android.util.Log

/**
 * The Details screen of HelloText (#025). It has no input of its own. Back returns to the main screen, and the main
 * screen logs `screen main` when it resumes.
 */
class DetailsActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_details)
    }

    override fun onResume() {
        super.onResume()
        FixtureState.screen = FixtureState.SCREEN_DETAILS
        Log.i(MainActivity.LOG_TAG, "screen ${FixtureState.SCREEN_DETAILS}")
    }
}
