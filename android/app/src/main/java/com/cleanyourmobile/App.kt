package com.cleanyourmobile

import android.app.Application

/**
 * Applies the saved theme before any Activity exists, so the first frame is
 * already correct. Doing this in an Activity instead makes the app paint the
 * wrong theme and then recreate itself, which is visible as a flash.
 */
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        ThemeMode.apply(ThemeMode.load(this))
    }
}
