package com.cleanyourmobile

/**
 * How much does removing this actually improve the phone?
 *
 * The safety rating says how risky a removal is. It says nothing about how
 * worthwhile it is, and those are different questions: a preinstalled compass
 * and a lock-screen ad carousel are both "Recommended", but only one of them is
 * doing you harm. This orders the list so the things people actually came here
 * for are at the top.
 */
enum class Priority(val label: String, val blurb: String) {
    HIGH("High impact", "Advertising, trackers and telemetry. You notice these going."),
    MEDIUM("Worth removing", "Preinstalled apps and duplicates you did not ask for."),
    LOW("Optional", "Manufacturer features you might actually use."),
    ;

    companion object {
        fun of(entry: Db.Pkg): Priority = when (entry.category) {
            // Actively working against you: serving ads, or sending data out.
            "ads", "tracker", "telemetry" -> HIGH
            // Dead weight: shipped with the phone, never asked for.
            "bloatware", "partner", "carrier" -> MEDIUM
            // You already have something better, but it is only clutter.
            "duplicate", "google" -> MEDIUM
            // A real feature. Removing it is a preference, not a fix.
            "oem_feature" -> LOW
            else -> LOW
        }
    }
}

/** The filter chips across the top of the list. */
enum class Filter(val label: String) {
    SUGGESTED("Suggested"),
    HIGH_IMPACT("Ads & tracking"),
    ALL("Everything"),
    KEPT("Protected"),
    // Installed, but the database has no entry for it. These used to be left
    // out of the list altogether, which on a ColorOS/realme UI/OxygenOS phone
    // silently hid a large slice of what is actually installed and read as
    // "the app does not detect my apps". They are shown, never offered.
    UNRATED("Unrated"),
    ;
}
