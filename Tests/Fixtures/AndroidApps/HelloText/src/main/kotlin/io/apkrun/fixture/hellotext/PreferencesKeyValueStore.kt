package io.apkrun.fixture.hellotext

import android.content.SharedPreferences

/** The SharedPreferences backing of [CounterStore]. `commit` writes before it returns, so a click survives a kill. */
class PreferencesKeyValueStore(private val preferences: SharedPreferences) : KeyValueStore {
    override fun getInt(key: String, defaultValue: Int): Int = preferences.getInt(key, defaultValue)

    override fun putInt(key: String, value: Int) {
        preferences.edit().putInt(key, value).commit()
    }
}
