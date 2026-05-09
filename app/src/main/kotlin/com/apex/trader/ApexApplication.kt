package com.apex.trader

import android.app.Application
import androidx.hilt.work.HiltWorkerFactory
import androidx.work.Configuration
import androidx.work.WorkManager
import dagger.hilt.android.HiltAndroidApp
import timber.log.Timber
import java.io.File
import java.io.FileWriter
import java.io.PrintWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import javax.inject.Inject

@HiltAndroidApp
class ApexApplication : Application(), Configuration.Provider {

    @Inject lateinit var workerFactory: HiltWorkerFactory

    override val workManagerConfiguration: Configuration
        get() = Configuration.Builder()
            .setWorkerFactory(workerFactory)
            .setMinimumLoggingLevel(android.util.Log.INFO)
            .build()

    override fun onCreate() {
        super.onCreate()
        if (BuildConfig.DEBUG) Timber.plant(Timber.DebugTree())
        Timber.plant(FileLoggingTree(this))
        installCrashHandler()
        // Touch WorkManager once now, while we're still in Application.onCreate and
        // the Hilt-injected workerFactory is guaranteed to be set on the same thread.
        // This way the lazy initialization (which calls our Configuration.Provider)
        // can never trigger from a user-interaction code path on the main thread —
        // e.g. mid-permission-grant — where a synchronous throw would kill the activity.
        runCatching { WorkManager.getInstance(this) }
            .onFailure { Timber.e(it, "WorkManager eager init failed") }
    }

    private fun installCrashHandler() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                Timber.e(throwable, "UNCAUGHT on ${thread.name}: ${throwable.javaClass.simpleName}: ${throwable.message}")
                writeCrashFile(thread, throwable)
            } catch (_: Throwable) {
                // Never let our handler block the system one.
            }
            previous?.uncaughtException(thread, throwable)
        }
    }

    private fun writeCrashFile(thread: Thread, throwable: Throwable) {
        val dir = getExternalFilesDir(null) ?: filesDir
        val file = File(dir, "apex-crash-latest.log")
        FileWriter(file, false).use { fw ->
            PrintWriter(fw).use { pw ->
                val ts = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US).format(Date())
                pw.println("Apex Trader crash $ts")
                pw.println("Thread: ${thread.name}")
                pw.println("Exception: ${throwable.javaClass.name}: ${throwable.message}")
                pw.println()
                throwable.printStackTrace(pw)
                var cause = throwable.cause
                while (cause != null && cause !== throwable) {
                    pw.println()
                    pw.println("Caused by: ${cause.javaClass.name}: ${cause.message}")
                    cause.printStackTrace(pw)
                    cause = cause.cause
                }
            }
        }
    }
}

/**
 * Writes ERROR-and-above log lines to a rolling file in the app's external files dir.
 * Helps users share a crash trace via "/sdcard/Android/data/com.apex.trader/files/apex.log".
 */
private class FileLoggingTree(private val app: Application) : Timber.DebugTree() {
    private val fmt = SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US)
    override fun log(priority: Int, tag: String?, message: String, t: Throwable?) {
        if (priority < android.util.Log.WARN) return
        runCatching {
            val dir = app.getExternalFilesDir(null) ?: app.filesDir
            val file = File(dir, "apex.log")
            // Rotate at 1MB.
            if (file.exists() && file.length() > 1_000_000L) {
                val backup = File(dir, "apex.log.1")
                if (backup.exists()) backup.delete()
                file.renameTo(backup)
            }
            FileWriter(file, true).use { fw ->
                fw.appendLine("${fmt.format(Date())} ${priorityLetter(priority)}/${tag ?: "Apex"}: $message")
                if (t != null) {
                    PrintWriter(fw).use { it.println(android.util.Log.getStackTraceString(t)) }
                }
            }
        }
    }

    private fun priorityLetter(p: Int) = when (p) {
        android.util.Log.VERBOSE -> "V"
        android.util.Log.DEBUG -> "D"
        android.util.Log.INFO -> "I"
        android.util.Log.WARN -> "W"
        android.util.Log.ERROR -> "E"
        else -> "?"
    }
}
