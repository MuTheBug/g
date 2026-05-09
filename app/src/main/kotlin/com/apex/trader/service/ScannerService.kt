package com.apex.trader.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.hilt.work.HiltWorker
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import com.apex.trader.MainActivity
import com.apex.trader.R
import com.apex.trader.data.repository.SettingsRepository
import com.apex.trader.domain.scanner.MarketScanner
import com.apex.trader.domain.strategy.Signal
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import kotlinx.coroutines.flow.first
import timber.log.Timber

@HiltWorker
class ScannerService @AssistedInject constructor(
    @Assisted appContext: Context,
    @Assisted params: WorkerParameters,
    private val scanner: MarketScanner,
    private val settingsRepository: SettingsRepository
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        return try {
            setForeground(makeForegroundInfo("Scanning Binance USDT-M…"))
            val settings = settingsRepository.settings.first()
            val signals = scanner.scan(parallelism = 4)
            val high = signals.filter { it.confidence >= settings.minConfidence }
            if (high.isNotEmpty()) notifySignals(high.take(5))
            Result.success()
        } catch (t: Throwable) {
            Timber.e(t, "scan worker failed")
            Result.retry()
        }
    }

    private fun makeForegroundInfo(text: String): ForegroundInfo {
        ensureChannel()
        val openAppIntent = PendingIntent.getActivity(
            applicationContext,
            0,
            Intent(applicationContext, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(applicationContext, CHANNEL_PROGRESS)
            .setContentTitle("Apex Scanner")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_apex_status)
            .setContentIntent(openAppIntent)
            .setOngoing(true)
            .setSilent(true)
            .build()
        return ForegroundInfo(NOTIF_ID_PROGRESS, notification)
    }

    private fun notifySignals(signals: List<Signal>) {
        ensureChannel()
        val nm = NotificationManagerCompat.from(applicationContext)
        val openAppIntent = PendingIntent.getActivity(
            applicationContext,
            0,
            Intent(applicationContext, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        signals.forEachIndexed { i, sig ->
            val title = "${sig.symbol} ${sig.side.name} • ${sig.confidence}%"
            val txt = "Entry ${"%.4f".format(sig.plan.entry)} • SL ${"%.4f".format(sig.plan.stopLoss)} • TP1 ${"%.4f".format(sig.plan.takeProfit1)}"
            val n: Notification = NotificationCompat.Builder(applicationContext, CHANNEL_SIGNALS)
                .setContentTitle(title)
                .setContentText(txt)
                .setStyle(NotificationCompat.BigTextStyle().bigText(txt))
                .setSmallIcon(R.drawable.ic_apex_status)
                .setContentIntent(openAppIntent)
                .setAutoCancel(true)
                .build()
            try {
                nm.notify(NOTIF_ID_SIGNAL_BASE + i, n)
            } catch (_: SecurityException) { /* notification permission missing — ignore */ }
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = applicationContext.getSystemService(NotificationManager::class.java)
        if (mgr.getNotificationChannel(CHANNEL_SIGNALS) == null) {
            mgr.createNotificationChannel(
                NotificationChannel(CHANNEL_SIGNALS, "Trading signals", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Notifies you when the scanner finds high-confidence setups"
                }
            )
        }
        if (mgr.getNotificationChannel(CHANNEL_PROGRESS) == null) {
            mgr.createNotificationChannel(
                NotificationChannel(CHANNEL_PROGRESS, "Scanner status", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Foreground notification while a scan is running"
                }
            )
        }
    }

    companion object {
        const val CHANNEL_SIGNALS = "apex_signals"
        const val CHANNEL_PROGRESS = "apex_progress"
        const val NOTIF_ID_PROGRESS = 1001
        const val NOTIF_ID_SIGNAL_BASE = 2000
        const val UNIQUE_NAME = "apex_periodic_scan"
    }
}
