package com.cleanyourmobile

import android.content.pm.PackageManager
import rikka.shizuku.Shizuku
import java.io.BufferedReader
import java.io.InputStreamReader

/**
 * Everything that needs shell privileges goes through here.
 *
 * Shizuku hands this app the same privilege level ADB has, so the commands
 * below are the exact ones scripts/debloat.sh runs. That parity is deliberate:
 * the shell path is the tested one, and running anything different here would
 * mean two behaviours to reason about instead of one.
 */
object ShizukuOps {

    const val PERMISSION_REQUEST_CODE = 4211

    data class Reply(val ok: Boolean, val output: String)

    enum class State { NOT_INSTALLED, NOT_RUNNING, NEEDS_PERMISSION, READY }

    private var managerInstalled: Boolean = false

    fun setManagerInstalled(value: Boolean) {
        managerInstalled = value
    }

    fun state(): State {
        if (!Shizuku.pingBinder()) {
            // pingBinder() is false both when Shizuku is absent and when it is
            // installed but not started. The two are indistinguishable from
            // here, so the caller tells us whether the manager app exists.
            return if (managerInstalled) State.NOT_RUNNING else State.NOT_INSTALLED
        }
        if (Shizuku.isPreV11()) return State.NOT_RUNNING
        return if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
            State.READY
        } else {
            State.NEEDS_PERMISSION
        }
    }

    fun requestPermission() = Shizuku.requestPermission(PERMISSION_REQUEST_CODE)

    /**
     * Run one command with shell privileges.
     *
     * Shizuku.newProcess is hidden API, so it is reached by reflection. The
     * alternative is binder calls into IPackageManager, which needs hidden-API
     * stubs and changes shape between Android versions. `pm` is a stable
     * contract and gives exact parity with the shell scripts.
     */
    private fun exec(vararg command: String): Reply {
        return try {
            val method = Shizuku::class.java.getDeclaredMethod(
                "newProcess",
                Array<String>::class.java,
                Array<String>::class.java,
                String::class.java,
            )
            method.isAccessible = true
            val process = method.invoke(null, arrayOf(*command), null, null) as Process

            // pm writes refusals to stderr. The shell path learned this the hard
            // way on a vivo, where discarding stderr turned every vendor block
            // into "no reply". Read both streams.
            val out = BufferedReader(InputStreamReader(process.inputStream)).use { it.readText() }
            val err = BufferedReader(InputStreamReader(process.errorStream)).use { it.readText() }
            process.waitFor()
            Reply(ok = true, output = (out + System.lineSeparator() + err).trim())
        } catch (t: Throwable) {
            Reply(ok = false, output = "could not run command: " + t.message)
        }
    }

    /** pm disable-user --user 0 - removes nothing, fully reversible. */
    fun disable(pkg: String): Reply {
        val r = exec("pm", "disable-user", "--user", "0", pkg)
        return r.copy(ok = r.output.contains("new state: disabled-user"))
    }

    /** pm uninstall -k --user 0 - keeps app data, keeps the system copy. */
    fun uninstall(pkg: String): Reply {
        val r = exec("pm", "uninstall", "-k", "--user", "0", pkg)
        return r.copy(ok = r.output.contains("Success"))
    }

    fun enable(pkg: String): Reply {
        val r = exec("pm", "enable", "--user", "0", pkg)
        return r.copy(ok = r.output.contains("new state: enabled"))
    }

    fun installExisting(pkg: String): Reply {
        val r = exec("cmd", "package", "install-existing", pkg)
        return r.copy(
            ok = r.output.contains("installed for user") || r.output.contains("Success")
        )
    }

    /** The health check: the package service must still answer. */
    fun packageServiceAlive(): Boolean =
        exec("cmd", "package", "list", "packages", "android")
            .output.contains("package:android")

    /**
     * Turn a pm error into something a person can act on. Kept in step with
     * explain_failure() in scripts/debloat.sh.
     */
    fun explainFailure(reply: String): String = when {
        reply.contains("SecurityException") && reply.contains("no root permission") ->
            "blocked by the vendor ROM (would need root, which this app will not use)"
        reply.contains("DELETE_FAILED_INTERNAL_ERROR") ->
            "the ROM refused the uninstall - try disable instead"
        reply.contains("DELETE_FAILED_DEVICE_POLICY_MANAGER") ->
            "a device policy or work profile owns this package"
        reply.contains("not installed for") -> "not installed for this user - nothing to do"
        reply.contains("Unknown package") -> "the phone does not know this package name"
        reply.isBlank() -> "no reply from the package service"
        else -> reply.lineSequence().firstOrNull { it.isNotBlank() }?.take(120) ?: "unknown error"
    }
}
