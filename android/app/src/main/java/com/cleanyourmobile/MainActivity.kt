package com.cleanyourmobile

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.Editable
import android.text.TextWatcher
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.FileProvider
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.button.MaterialButton
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.card.MaterialCardView
import com.google.android.material.checkbox.MaterialCheckBox
import com.google.android.material.chip.Chip
import com.google.android.material.chip.ChipGroup
import com.google.android.material.progressindicator.LinearProgressIndicator
import com.google.android.material.textfield.TextInputEditText
import rikka.shizuku.Shizuku
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.concurrent.thread

class MainActivity : AppCompatActivity() {

    data class Row(
        val id: String,
        val entry: Db.Pkg,
        val priority: Priority,
        val blockedBecause: String?,
        val alreadyOff: Boolean,
        var selected: Boolean = false,
        /** Installed but absent from the database: shown, never offered. */
        val unrated: Boolean = false,
    ) {
        val actionable: Boolean get() = blockedBecause == null && !alreadyOff
    }

    private lateinit var db: Db
    private lateinit var brand: Brand
    private lateinit var backup: Backup

    private lateinit var deviceName: TextView
    private lateinit var deviceSub: TextView
    private lateinit var brandNotes: TextView
    private lateinit var shizukuCard: MaterialCardView
    private lateinit var shizukuStatus: TextView
    private lateinit var shizukuAction: MaterialButton
    private lateinit var summary: TextView
    private lateinit var progress: LinearProgressIndicator
    private lateinit var listView: RecyclerView
    private lateinit var filters: ChipGroup
    private lateinit var searchInput: TextInputEditText
    private lateinit var actionBar: MaterialCardView
    private lateinit var selectedCount: TextView
    private lateinit var runButton: MaterialButton

    private val all = mutableListOf<Row>()
    private val shown = mutableListOf<Row>()
    private val adapter = Adapter()
    private val main = Handler(Looper.getMainLooper())

    private var filter = Filter.SUGGESTED
    private var query = ""

    /** Matches scripts/debloat.sh. AGENTS.md: not six, not "just this once". */
    private val batchSize = 5
    private val maxConsecutiveFailures = 3

    private val permissionListener = Shizuku.OnRequestPermissionResultListener { _, _ -> refresh() }
    private val binderReceived = Shizuku.OnBinderReceivedListener { refresh() }
    private val binderDead = Shizuku.OnBinderDeadListener { refresh() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        setSupportActionBar(findViewById(R.id.toolbar))
        bindViews()

        db = try {
            Db.load(this)
        } catch (t: Throwable) {
            fatal("Cannot start: " + t.message)
            return
        }
        if (Guard.guardUnusable(db)) {
            fatal(
                "Cannot start: the never-touch list looks truncated (" +
                    db.essentials.size + " entries). Refusing to run without a guard."
            )
            return
        }

        backup = Backup(this)
        buildFilterChips()

        Shizuku.addRequestPermissionResultListener(permissionListener)
        Shizuku.addBinderReceivedListenerSticky(binderReceived)
        Shizuku.addBinderDeadListener(binderDead)

        scan()
        refresh()
    }

    override fun onDestroy() {
        super.onDestroy()
        Shizuku.removeRequestPermissionResultListener(permissionListener)
        Shizuku.removeBinderReceivedListener(binderReceived)
        Shizuku.removeBinderDeadListener(binderDead)
    }

    private fun bindViews() {
        deviceName = findViewById(R.id.deviceName)
        deviceSub = findViewById(R.id.deviceSub)
        brandNotes = findViewById(R.id.brandNotes)
        shizukuCard = findViewById(R.id.shizukuCard)
        shizukuStatus = findViewById(R.id.shizukuStatus)
        shizukuAction = findViewById(R.id.shizukuAction)
        summary = findViewById(R.id.summary)
        progress = findViewById(R.id.progress)
        listView = findViewById(R.id.list)
        filters = findViewById(R.id.filters)
        searchInput = findViewById(R.id.searchInput)
        actionBar = findViewById(R.id.actionBar)
        selectedCount = findViewById(R.id.selectedCount)
        runButton = findViewById(R.id.runButton)

        listView.layoutManager = LinearLayoutManager(this)
        listView.adapter = adapter

        searchInput.addTextChangedListener(object : TextWatcher {
            override fun afterTextChanged(s: Editable?) {
                query = s?.toString()?.trim()?.lowercase() ?: ""
                applyFilter()
            }
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
        })

        findViewById<MaterialButton>(R.id.clearSelection).setOnClickListener {
            all.forEach { it.selected = false }
            applyFilter()
        }
        runButton.setOnClickListener { confirmAndRun() }
    }

    private fun fatal(message: String) {
        shizukuStatus.text = message
        shizukuAction.isEnabled = false
        deviceName.text = "Clean Your Mobile"
    }

    private fun buildFilterChips() {
        // The selected chip has to be unmistakable: at default Material tinting
        // on this dark palette, checked and unchecked were nearly identical.
        val accent = androidx.core.content.ContextCompat.getColor(this, R.color.cym_accent)
        val onAccent = androidx.core.content.ContextCompat.getColor(this, R.color.cym_on_accent)
        val muted = androidx.core.content.ContextCompat.getColor(this, R.color.cym_muted_foreground)
        val border = androidx.core.content.ContextCompat.getColor(this, R.color.cym_border)
        val states = arrayOf(intArrayOf(android.R.attr.state_checked), intArrayOf())

        for (f in Filter.values()) {
            val chip = Chip(this).apply {
                text = f.label
                isCheckable = true
                isChecked = f == filter
                chipBackgroundColor = android.content.res.ColorStateList(
                    states, intArrayOf(accent, android.graphics.Color.TRANSPARENT)
                )
                setTextColor(
                    android.content.res.ColorStateList(states, intArrayOf(onAccent, muted))
                )
                chipStrokeWidth = resources.displayMetrics.density * 1f
                chipStrokeColor = android.content.res.ColorStateList(
                    states, intArrayOf(accent, border)
                )
                isCheckedIconVisible = false
                setOnClickListener {
                    filter = f
                    applyFilter()
                }
            }
            filters.addView(chip)
        }
    }

    /**
     * Reflect a filter change made in code - importing a preset switches to
     * "Everything" so the selection is visible - in the chip row, which
     * otherwise keeps showing the old one as checked.
     */
    private fun syncFilterChips() {
        val values = Filter.values()
        for (i in 0 until filters.childCount) {
            val chip = filters.getChildAt(i) as? Chip ?: continue
            if (i < values.size) chip.isChecked = values[i] == filter
        }
    }

    // ----------------------------------------------------------------- scan --

    private fun liveState(): Guard.LiveState {
        val home = packageManager.resolveActivity(
            Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME),
            PackageManager.MATCH_DEFAULT_ONLY,
        )?.activityInfo?.packageName
        val ime = Settings.Secure.getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
            ?.substringBefore('/')
        return Guard.LiveState(home, ime)
    }

    private fun scan() {
        val installed = packageManager.getInstalledApplications(0)
        val names = installed.map { it.packageName }
        brand = Brand.detect(this, names)

        val live = liveState()
        all.clear()
        var recognised = 0
        var blocked = 0
        var off = 0
        var unrated = 0
        var regular = 0

        for (app in installed) {
            // Not a system app: no system copy to fall back on, so never offered.
            if (app.flags and ApplicationInfo.FLAG_SYSTEM == 0) {
                regular++
                continue
            }
            val id = app.packageName
            val entry = db.packages[id]
            if (entry == null) {
                // Not in the database, but the never-touch list still covers it.
                // Counting these as "unknown" made the guard look far less
                // active than it is. Same fix as the one in tools/scan.py.
                if (db.essentials.contains(id)) {
                    blocked++
                    continue
                }
                // Previously this just `continue`d, so an installed package the
                // database did not know never appeared anywhere in the app. On
                // an oplus phone that is a large slice of what is installed,
                // and it read as the app failing to detect anything. Show it,
                // marked unrated, and never offer it: an unrated package is
                // evidence for a human, not a verdict.
                unrated++
                all.add(
                    Row(
                        id = id,
                        entry = Db.Pkg(
                            id = id,
                            brand = "",
                            category = "unknown",
                            safety = "Unrated",
                            name = id,
                            description = "",
                            ifRemoved = "",
                        ),
                        priority = Priority.LOW,
                        blockedBecause = "not in the database",
                        alreadyOff = !app.enabled,
                        unrated = true,
                    )
                )
                continue
            }
            recognised++
            val reason = Guard.blockReason(id, db, live)
            if (reason != null) blocked++
            if (!app.enabled) off++
            all.add(Row(id, entry, Priority.of(entry), reason, !app.enabled))
        }

        // Highest impact first, then most cautious last within each band.
        all.sortWith(compareBy({ it.priority.ordinal }, { it.entry.rank }, { it.entry.name }))

        deviceName.text = Build.MANUFACTURER.replaceFirstChar { it.uppercase() } +
            " " + Build.MODEL
        deviceSub.text = buildString {
            append(brand.displayName)
            if (brand.osName.isNotBlank()) append(" · ").append(brand.osName)
            append(" · Android ").append(Build.VERSION.RELEASE)
        }
        if (brand.notes.isNotBlank()) {
            brandNotes.text = brand.notes
            brandNotes.visibility = View.VISIBLE
        } else {
            brandNotes.visibility = View.GONE
        }

        summary.text = installed.size.toString() + " installed · " + recognised +
            " recognised · " + blocked + " protected · " + unrated + " unrated · " +
            off + " already off · " + regular + " regular apps left alone"

        applyFilter()
    }

    private fun applyFilter() {
        shown.clear()
        for (row in all) {
            val passesFilter = when (filter) {
                Filter.SUGGESTED -> row.actionable && row.priority != Priority.LOW &&
                    row.entry.safety == "Recommended"
                Filter.HIGH_IMPACT -> row.actionable && row.priority == Priority.HIGH
                Filter.ALL -> row.actionable
                // Unrated rows are non-actionable too, so keep them out of
                // "Protected" or they would bury the genuinely protected ones.
                Filter.KEPT -> !row.actionable && !row.unrated
                Filter.UNRATED -> row.unrated
            }
            if (!passesFilter) continue
            if (query.isNotEmpty() &&
                !row.entry.name.lowercase().contains(query) &&
                !row.id.lowercase().contains(query)
            ) continue
            shown.add(row)
        }
        adapter.notifyDataSetChanged()
        updateActionBar()
    }

    private fun updateActionBar() {
        val n = all.count { it.selected }
        if (n == 0) {
            actionBar.visibility = View.GONE
        } else {
            actionBar.visibility = View.VISIBLE
            selectedCount.text = n.toString() + " selected"
        }
    }

    // ---------------------------------------------------------------- state --

    private fun shizukuManagerInstalled(): Boolean = try {
        packageManager.getPackageInfo("moe.shizuku.privileged.api", 0)
        true
    } catch (e: PackageManager.NameNotFoundException) {
        false
    }

    private fun refresh() {
        ShizukuOps.setManagerInstalled(shizukuManagerInstalled())
        when (ShizukuOps.state()) {
            ShizukuOps.State.NOT_INSTALLED -> showShizuku(
                "Shizuku is not installed. It is what lets this app change apps " +
                    "without root.\n\nGet the GitHub release from " +
                    "github.com/RikkaApps/Shizuku - the Play Store build is older " +
                    "and has no Android 16 support.",
                "Re-check"
            ) { refresh() }

            ShizukuOps.State.NOT_RUNNING -> showShizuku(
                "Shizuku is installed but not running.\n\nOpen it and start the " +
                    "service: pair over Wireless debugging on Android 11+, or start " +
                    "it from a computer over ADB. Android clears it on every reboot.",
                "Open Shizuku"
            ) {
                packageManager.getLaunchIntentForPackage("moe.shizuku.privileged.api")
                    ?.let { startActivity(it) } ?: refresh()
            }

            ShizukuOps.State.NEEDS_PERMISSION -> showShizuku(
                "Shizuku is running and this app needs your permission to use it.",
                "Grant access"
            ) { ShizukuOps.requestPermission() }

            ShizukuOps.State.READY -> {
                shizukuCard.visibility = View.GONE
                runButton.isEnabled = true
            }
        }
    }

    private fun showShizuku(text: String, button: String, action: () -> Unit) {
        shizukuCard.visibility = View.VISIBLE
        shizukuStatus.text = text
        shizukuAction.text = button
        shizukuAction.setOnClickListener { action() }
        runButton.isEnabled = false
    }

    // ------------------------------------------------------------- the run --

    private fun confirmAndRun() {
        if (ShizukuOps.state() != ShizukuOps.State.READY) {
            Toast.makeText(this, "Shizuku is not connected", Toast.LENGTH_SHORT).show()
            return
        }
        val chosen = all.filter { it.selected && it.actionable }
        if (chosen.isEmpty()) return

        val preview = chosen.take(10).joinToString("\n") { "• " + it.entry.name }
        val more = if (chosen.size > 10) "\n…and " + (chosen.size - 10) + " more" else ""
        AlertDialog.Builder(this)
            .setTitle("Disable " + chosen.size + " app" + (if (chosen.size == 1) "" else "s") + "?")
            .setMessage(
                preview + more +
                    "\n\nThey are disabled, not uninstalled. Nothing is deleted and " +
                    "Restore puts them back.\n\nA snapshot of the phone is saved first."
            )
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Disable") { _, _ -> run(chosen) }
            .show()
    }

    private fun run(chosen: List<Row>) {
        runButton.isEnabled = false
        progress.visibility = View.VISIBLE
        progress.max = chosen.size
        progress.progress = 0

        thread {
            // AGENTS.md rule 4: the record and the baseline exist before the
            // first change, not after the last one.
            backup.captureSnapshot(brand)
            backup.startSession()

            var done = 0
            var failed = 0
            var consecutive = 0
            val problems = mutableListOf<String>()

            for ((i, row) in chosen.withIndex()) {
                // The guard runs again here: the default launcher or keyboard
                // may have changed since the scan.
                val reason = Guard.blockReason(row.id, db, liveState())
                if (reason != null) {
                    problems.add(row.entry.name + ": refused, " + reason)
                    failed++
                    continue
                }

                val reply = ShizukuOps.disable(row.id)
                if (reply.ok) {
                    backup.recordDisabled(row.id)
                    done++
                    consecutive = 0
                } else {
                    failed++
                    consecutive++
                    problems.add(row.entry.name + ": " + ShizukuOps.explainFailure(reply.output))
                    if (consecutive >= maxConsecutiveFailures) {
                        problems.add(
                            "Stopped after " + consecutive + " failures in a row — " +
                                "something systemic changed rather than one awkward app."
                        )
                        break
                    }
                }

                val p = i + 1
                main.post { progress.progress = p }

                if (p % batchSize == 0 && !ShizukuOps.packageServiceAlive()) {
                    problems.add("The package service stopped answering — stopping here.")
                    break
                }
            }

            val d = done
            val f = failed
            main.post {
                progress.visibility = View.GONE
                runButton.isEnabled = true
                all.forEach { it.selected = false }
                scan()
                val detail = if (problems.isEmpty()) "" else "\n\n" + problems.joinToString("\n")
                AlertDialog.Builder(this)
                    .setTitle(if (f == 0) "Done" else "Finished with problems")
                    .setMessage("Disabled: " + d + "\nFailed: " + f + detail)
                    .setPositiveButton("OK", null)
                    .show()
            }
        }
    }

    // --------------------------------------------------------------- menu ----

    override fun onCreateOptionsMenu(menu: android.view.Menu): Boolean {
        menu.add(0, 1, 0, "Restore all")
        menu.add(0, 2, 0, "Export backup")
        menu.add(0, 3, 0, "Export preset")
        menu.add(0, 4, 0, "Import preset")
        menu.add(0, 5, 0, "Appearance")
        return true
    }

    override fun onOptionsItemSelected(item: android.view.MenuItem): Boolean {
        when (item.itemId) {
            1 -> confirmRestoreAll()
            2 -> exportBackup()
            3 -> exportPreset()
            4 -> chooseImportSource()
            5 -> chooseTheme()
            else -> return super.onOptionsItemSelected(item)
        }
        return true
    }

    private fun confirmRestoreAll() {
        val packages = backup.stillOff()
        if (packages.isEmpty()) {
            Toast.makeText(this, "Nothing is currently switched off", Toast.LENGTH_SHORT).show()
            return
        }
        AlertDialog.Builder(this)
            .setTitle("Restore " + packages.size + " app(s)?")
            .setMessage("Everything this app switched off will be switched back on.")
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Restore") { _, _ ->
                thread {
                    var ok = 0
                    for (p in packages) {
                        if (ShizukuOps.enable(p).ok) ok++ else ShizukuOps.installExisting(p)
                    }
                    val n = ok
                    main.post {
                        backup.clearRecord()
                        scan()
                        Toast.makeText(this, "Restored " + n + " app(s)", Toast.LENGTH_LONG).show()
                    }
                }
            }
            .show()
    }

    private fun chooseTheme() {
        val modes = ThemeMode.values()
        val current = ThemeMode.load(this)
        AlertDialog.Builder(this)
            .setTitle("Appearance")
            .setSingleChoiceItems(
                modes.map { it.label }.toTypedArray(),
                modes.indexOf(current),
            ) { dialog, which ->
                val picked = modes[which]
                ThemeMode.save(this, picked)
                // Takes effect immediately: the delegate swaps the resource
                // bucket and recreates the activity for us.
                ThemeMode.apply(picked)
                dialog.dismiss()
            }
            .setNegativeButton("Close", null)
            .show()
    }

    // ------------------------------------------------------------- presets ---

    /**
     * The file picker for an imported preset. Registered as a property so it
     * exists before the activity is started, which is what the contract API
     * requires.
     */
    private val pickPreset = registerForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        if (uri == null) return@registerForActivityResult
        val text = try {
            contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }
        } catch (t: Throwable) {
            null
        }
        if (text.isNullOrBlank()) {
            Toast.makeText(this, "Could not read that file", Toast.LENGTH_LONG).show()
        } else {
            handlePresetText(text)
        }
    }

    /**
     * Share what this app actually switched off, as a preset another phone or
     * the command line tools can read.
     */
    private fun exportPreset() {
        val packages = backup.stillOff()
        if (packages.isEmpty()) {
            Toast.makeText(
                this, "Nothing is switched off yet - there is nothing to save",
                Toast.LENGTH_LONG,
            ).show()
            return
        }
        try {
            val preset = Preset.build(
                name = Build.MANUFACTURER + "-" + Build.MODEL,
                packages = packages,
                description = "Switched off with Clean Your Mobile on " +
                    Build.MANUFACTURER + " " + Build.MODEL +
                    ", Android " + Build.VERSION.RELEASE,
                brand = brand.key,
                mode = "disable",
            )
            val file = Preset.writeForShare(this, preset)
            val uri = FileProvider.getUriForFile(this, packageName + ".files", file)
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "application/json"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(send, "Export preset"))
        } catch (t: Throwable) {
            Toast.makeText(this, "Could not export: " + t.message, Toast.LENGTH_LONG).show()
        }
    }

    private fun chooseImportSource() {
        AlertDialog.Builder(this)
            .setTitle("Import a preset")
            .setItems(arrayOf("From a file", "From the clipboard")) { _, which ->
                if (which == 0) {
                    // Some providers mislabel .json, so accept anything and let
                    // the parser be the judge.
                    pickPreset.launch(arrayOf("*/*"))
                } else {
                    val clip = (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager)
                        .primaryClip
                    val text = if (clip != null && clip.itemCount > 0) {
                        clip.getItemAt(0).coerceToText(this).toString()
                    } else {
                        ""
                    }
                    if (text.isBlank()) {
                        Toast.makeText(this, "The clipboard is empty", Toast.LENGTH_LONG).show()
                    } else {
                        handlePresetText(text)
                    }
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    /**
     * Parse, then explain, then tick boxes. Importing a preset never changes
     * anything on the phone: it selects what the guard allows, and the normal
     * guarded flow still has to be run deliberately afterwards.
     */
    private fun handlePresetText(text: String) {
        when (val outcome = Preset.parse(text)) {
            is Preset.Outcome.Refused -> AlertDialog.Builder(this)
                .setTitle("Preset refused")
                .setMessage(
                    outcome.why + "\n\nNothing was imported and nothing on the phone " +
                        "was touched."
                )
                .setPositiveButton("Close", null)
                .show()

            is Preset.Outcome.Ok -> showPresetPlan(outcome.preset)
        }
    }

    private fun showPresetPlan(preset: Preset.Data) {
        val installedApps = packageManager.getInstalledApplications(0)
        val systemApps = installedApps.filter { it.flags and ApplicationInfo.FLAG_SYSTEM != 0 }
        val installed = systemApps.map { it.packageName }.toSet()
        val disabled = systemApps.filter { !it.enabled }.map { it.packageName }.toSet()
        val regular = installedApps.map { it.packageName }.toSet() - installed

        val res = Preset.resolve(preset, db, liveState(), installed, disabled)
        val notInstalled = res.notInstalled.filter { it !in regular }
        val leftAlone = res.notInstalled.filter { it in regular }

        val sb = StringBuilder()
        if (preset.description.isNotBlank()) sb.append(preset.description).append("\n\n")
        sb.append(preset.packages.size).append(" packages in this preset.\n")

        if (res.ready.isNotEmpty()) {
            sb.append("\nWill be selected (").append(res.ready.size).append("):\n")
            for (p in res.ready.take(20)) {
                sb.append("  ").append(p.name.ifBlank { p.id })
                    .append(" [").append(p.safety).append("]\n")
            }
            if (res.ready.size > 20) sb.append("  ... and ")
                .append(res.ready.size - 20).append(" more\n")
        }
        if (res.refused.isNotEmpty()) {
            sb.append("\nRefused by the guard (").append(res.refused.size)
                .append(") - no flag overrides this:\n")
            for ((id, why) in res.refused.take(10)) {
                sb.append("  ").append(id).append(" - ").append(why).append("\n")
            }
            if (res.refused.size > 10) sb.append("  ... and ")
                .append(res.refused.size - 10).append(" more\n")
        }
        if (res.readyUnknown.isNotEmpty()) {
            sb.append("\nNot in the database (").append(res.readyUnknown.size)
                .append(") - unrated, so not selected:\n")
            for (id in res.readyUnknown.take(10)) sb.append("  ").append(id).append("\n")
            if (res.readyUnknown.size > 10) sb.append("  ... and ")
                .append(res.readyUnknown.size - 10).append(" more\n")
        }
        if (res.alreadyOff.isNotEmpty()) {
            sb.append("\nAlready off: ").append(res.alreadyOff.size).append("\n")
        }
        if (leftAlone.isNotEmpty()) {
            sb.append("\nRegular apps, left alone: ").append(leftAlone.size)
                .append(" - not system apps, so a removal could not be undone.\n")
        }
        if (notInstalled.isNotEmpty()) {
            sb.append("\nNot on this phone: ").append(notInstalled.size)
                .append(" - this preset came from a different model.\n")
        }

        val selectable = res.ready.map { it.id }.toSet()
        val builder = AlertDialog.Builder(this)
            .setTitle("Preset: " + preset.name)
            .setMessage(sb.toString())
            .setNegativeButton("Cancel", null)

        if (selectable.isEmpty()) {
            builder.setPositiveButton("Close", null)
        } else {
            builder.setPositiveButton("Select " + selectable.size) { _, _ ->
                var ticked = 0
                for (row in all) {
                    if (row.actionable && selectable.contains(row.id)) {
                        row.selected = true
                        ticked++
                    }
                }
                // Show them: the default filter would hide most of a preset.
                filter = Filter.ALL
                syncFilterChips()
                applyFilter()
                Toast.makeText(
                    this, "Selected " + ticked + " app(s) - review, then switch off",
                    Toast.LENGTH_LONG,
                ).show()
            }
        }
        builder.show()
    }

    private fun exportBackup() {
        try {
            backup.captureSnapshot(brand)
            val file = backup.exportText()
            val uri = FileProvider.getUriForFile(this, packageName + ".files", file)
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(send, "Export backup"))
        } catch (t: Throwable) {
            Toast.makeText(this, "Could not export: " + t.message, Toast.LENGTH_LONG).show()
        }
    }

    // --------------------------------------------------------------- adapter --

    private inner class Adapter : RecyclerView.Adapter<Adapter.Holder>() {
        inner class Holder(view: View) : RecyclerView.ViewHolder(view) {
            val card: MaterialCardView = view.findViewById(R.id.card)
            val check: MaterialCheckBox = view.findViewById(R.id.check)
            val name: TextView = view.findViewById(R.id.name)
            val pkg: TextView = view.findViewById(R.id.pkg)
            val impact: TextView = view.findViewById(R.id.impact)
            val badges: ChipGroup = view.findViewById(R.id.badges)
        }

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): Holder =
            Holder(LayoutInflater.from(parent.context).inflate(R.layout.row_package, parent, false))

        override fun getItemCount(): Int = shown.size

        /**
         * Badges carry colour as reinforcement, never as the only signal: the
         * label still says "High impact" or "Expert" in words, which is the
         * skill's colour-not-only accessibility rule.
         */
        private fun badge(text: String, tint: Int): Chip = Chip(this@MainActivity).apply {
            this.text = text
            isClickable = false
            isCheckable = false
            // Inline labels, not tap targets: without this they render
            // at full 48dp touch-target height and dwarf the row.
            setEnsureMinTouchTargetSize(false)
            chipMinHeight = resources.displayMetrics.density * 26f
            chipStartPadding = resources.displayMetrics.density * 2f
            chipEndPadding = resources.displayMetrics.density * 2f
            textSize = 11f
            val colour = androidx.core.content.ContextCompat.getColor(context, tint)
            chipStrokeWidth = resources.displayMetrics.density * 1f
            chipStrokeColor = android.content.res.ColorStateList.valueOf(colour)
            setTextColor(colour)
            chipBackgroundColor = android.content.res.ColorStateList.valueOf(
                android.graphics.Color.TRANSPARENT
            )
        }

        private fun safetyTint(safety: String): Int = when (safety) {
            "Recommended" -> R.color.cym_accent
            "Advanced" -> R.color.cym_foreground
            else -> R.color.cym_warning
        }

        private fun priorityTint(p: Priority): Int = when (p) {
            Priority.HIGH -> R.color.cym_accent
            Priority.MEDIUM -> R.color.cym_muted_foreground
            Priority.LOW -> R.color.cym_muted_foreground
        }

        override fun onBindViewHolder(holder: Holder, position: Int) {
            val row = shown[position]
            holder.name.text = row.entry.name
            holder.pkg.text = row.id

            holder.badges.removeAllViews()
            holder.badges.addView(badge(row.entry.safety, safetyTint(row.entry.safety)))
            if (row.actionable) {
                holder.badges.addView(badge(row.priority.label, priorityTint(row.priority)))
            }

            when {
                row.alreadyOff -> {
                    holder.impact.text = "Already switched off."
                    holder.check.isChecked = false
                    holder.card.isEnabled = false
                    holder.card.alpha = 0.5f
                    holder.card.setOnClickListener(null)
                }
                row.unrated -> {
                    // Honest wording: this one is not protected, it is simply
                    // not rated. Saying "Protected" here would be a lie.
                    holder.impact.text =
                        "Not in the database - unrated. Nothing is known about what " +
                            "removing it would cost, so it is not offered. Report it " +
                            "and it can be rated."
                    holder.check.isChecked = false
                    holder.card.isEnabled = false
                    holder.card.alpha = 0.5f
                    holder.card.setOnClickListener(null)
                }
                !row.actionable -> {
                    // Shown, never offered. The user should know it was seen.
                    holder.impact.text = "Protected: " + row.blockedBecause
                    holder.check.isChecked = false
                    holder.card.isEnabled = false
                    holder.card.alpha = 0.5f
                    holder.card.setOnClickListener(null)
                }
                else -> {
                    holder.impact.text = "If removed: " + row.entry.ifRemoved
                    holder.check.isChecked = row.selected
                    holder.card.isEnabled = true
                    holder.card.alpha = 1f
                    holder.card.isChecked = row.selected
                    holder.card.setOnClickListener {
                        row.selected = !row.selected
                        holder.check.isChecked = row.selected
                        holder.card.isChecked = row.selected
                        updateActionBar()
                    }
                }
            }
        }
    }
}
