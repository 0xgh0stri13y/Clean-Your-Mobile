package com.cleanyourmobile

import android.content.Context
import androidx.appcompat.app.AppCompatDelegate

/**
 * Light / Dark / System, remembered between launches.
 *
 * AppCompatDelegate swaps which resource bucket resolves - values/ or
 * values-night/ - so one DayNight theme covers both and the switch needs no
 * restart. Applied in Application.onCreate so the very first frame is already
 * the right one; setting it in an Activity makes the app flash the wrong
 * theme and then recreate itself.
 */
enum class ThemeMode(val label: String, val delegateMode: Int) {
    SYSTEM("Follow system", AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM),
    LIGHT("Light", AppCompatDelegate.MODE_NIGHT_NO),
    DARK("Dark (OLED black)", AppCompatDelegate.MODE_NIGHT_YES),
    ;

    companion object {
        private const val PREFS = "cym_prefs"
        private const val KEY = "theme_mode"

        fun load(context: Context): ThemeMode {
            val name = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(KEY, DARK.name)
            return values().firstOrNull { it.name == name } ?: DARK
        }

        fun save(context: Context, mode: ThemeMode) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putString(KEY, mode.name).apply()
        }

        fun apply(mode: ThemeMode) {
            AppCompatDelegate.setDefaultNightMode(mode.delegateMode)
        }
    }
}
