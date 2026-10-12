package io.apkrun.fixture.hellocompose

import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.launch

/**
 * The only Activity of HelloCompose: a [TextField] above a [LazyColumn] of [ListRows.COUNT] rows. It logs
 * `APKRUN-FIXTURE: scroll first=<index>` when the first visible row settles on a new index, and
 * `APKRUN-FIXTURE: text length=<n>` when the field changes. The typed text is never logged.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                FixtureScreen()
            }
        }
    }

    companion object {
        /** The logcat tag of the event lines. */
        const val LOG_TAG = "APKRUN-FIXTURE"

        /** How long the first visible index must hold before it is logged as settled. */
        const val SCROLL_SETTLE_MILLIS = 300L

        /**
         * The screen while it is shown, for the debug receiver (src/debug). Null when no list is shown. The debug
         * receiver runs on the main thread, as does the composition, so the field needs no lock.
         */
        var debugHost: DebugComposeHost? = null
    }
}

@Composable
private fun FixtureScreen() {
    val listState = rememberLazyListState()
    val text = remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()

    DisposableEffect(listState, scope) {
        val host = object : DebugComposeHost {
            override fun scrollTo(index: Int) {
                scope.launch { listState.scrollToItem(index) }
            }

            override fun setText(value: String) {
                text.value = value
            }
        }
        MainActivity.debugHost = host
        onDispose {
            if (MainActivity.debugHost === host) {
                MainActivity.debugHost = null
            }
        }
    }

    LaunchedEffect(listState) {
        val reporter = ScrollReporter()
        snapshotFlow { listState.firstVisibleItemIndex }
            .debounce(MainActivity.SCROLL_SETTLE_MILLIS)
            .collect { first ->
                reporter.settled(first)?.let { Log.i(MainActivity.LOG_TAG, it) }
            }
    }

    Scaffold { innerPadding ->
        Column(Modifier.fillMaxSize().padding(innerPadding).padding(16.dp)) {
            TextField(
                value = text.value,
                onValueChange = { value ->
                    text.value = value
                    Log.i(MainActivity.LOG_TAG, "text length=${value.length}")
                },
                label = { Text(stringResource(R.string.input_label)) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            LazyColumn(state = listState, modifier = Modifier.fillMaxWidth()) {
                items(ListRows.COUNT) { index ->
                    Text(text = "Row $index", modifier = Modifier.fillMaxWidth().height(48.dp))
                }
            }
        }
    }
}
