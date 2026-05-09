package com.apex.trader.service

import android.content.Context
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import dagger.hilt.android.qualifiers.ApplicationContext
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ScanWorkerScheduler @Inject constructor(
    @ApplicationContext private val context: Context
) {
    /** Schedule the recurring scan. Min interval is 15m (WorkManager constraint). */
    fun enable(intervalMinutes: Int) {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .setRequiresBatteryNotLow(true)
            .build()
        val req = PeriodicWorkRequestBuilder<ScannerService>(
            intervalMinutes.toLong().coerceAtLeast(15),
            TimeUnit.MINUTES
        ).setConstraints(constraints).build()
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            ScannerService.UNIQUE_NAME_PERIODIC,
            ExistingPeriodicWorkPolicy.UPDATE,
            req
        )
    }

    fun disable() {
        WorkManager.getInstance(context).cancelUniqueWork(ScannerService.UNIQUE_NAME_PERIODIC)
    }

    /**
     * Trigger a single scan immediately. Useful as a "run now" affordance — the
     * resulting notification (if any) verifies the background path is wired up
     * end-to-end without waiting for the 15-minute periodic window.
     *
     * Uses [OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST] as a fallback when
     * the device is out of expedited quota so the request never gets rejected.
     */
    fun runOnce() {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()
        val req = OneTimeWorkRequestBuilder<ScannerService>()
            .setConstraints(constraints)
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(
            ScannerService.UNIQUE_NAME_ONESHOT,
            ExistingWorkPolicy.REPLACE,
            req
        )
    }
}
