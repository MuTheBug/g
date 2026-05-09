package com.apex.trader

import android.app.Application
import androidx.hilt.work.HiltWorkerFactory
import androidx.work.Configuration
import dagger.hilt.android.HiltAndroidApp
import timber.log.Timber
import javax.inject.Inject

@HiltAndroidApp
class ApexApplication : Application(), Configuration.Provider {

    @Inject lateinit var workerFactory: HiltWorkerFactory

    override val workManagerConfiguration: Configuration
        get() = Configuration.Builder()
            .setWorkerFactory(workerFactory)
            .build()

    override fun onCreate() {
        super.onCreate()
        if (BuildConfig.DEBUG) Timber.plant(Timber.DebugTree())
        installCrashHandler()
    }

    private fun installCrashHandler() {
        // Daisy-chain on top of the system handler so we still get the standard
        // "App stopped" dialog + Play Console reporting, but with our own log line
        // that survives in logcat for diagnosis.
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                Timber.e(throwable, "UNCAUGHT on ${thread.name}: ${throwable.javaClass.simpleName}: ${throwable.message}")
            } catch (_: Throwable) { /* never let our handler block the system one */ }
            previous?.uncaughtException(thread, throwable)
        }
    }
}
