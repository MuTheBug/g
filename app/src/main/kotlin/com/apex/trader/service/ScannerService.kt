package com.apex.trader.service

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
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
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.first
import timber.log.Timber

/**
 * Runs a market scan periodically (or on demand) and posts a notification per
 * high-confidence signal. Defensive against missing permissions, FGS restrictions,
 * and notification API quirks — every system call that can fail is wrapped so the
 * worker degrades gracefully instead of crashing the app process.
 */
@HiltWorker
class ScannerService @AssistedInject constructor(
    @Assisted appContext: Context,
    @Assisted params: WorkerParameters,
    private val scanner: MarketScanner,
    private val settingsRepository: SettingsRepository
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        // Always create channels first — both the foreground and signal channels must
        // exist before any setForeground/notify call or those calls silently no-op (or,
        // on some OEMs, throw).
        runCatching { ensureChannels() }
            .onFailure { Timber.w(it, "channel setup failed") }

        // Going foreground is best-effort. If POST_NOTIFICATIONS is denied, FGS is
        // restricted, or any other reason — we keep running in the background. The
        // worker still has up to 10 minutes to complete its scan.
        runCatching {
            if (canPostNotifications()) {
                setForeground(makeForegroundInfo("Scanning Binance USDT-M…"))
            }
        }.onFailure { Timber.w(it, "setForeground skipped") }

        return try {
            val settings = settingsRepository.settings.first()
            val signals = scanner.scan(parallelism = 4)
            val high = signals.filter { it.confidence >= settings.minConfidence }
            if (high.isNotEmpty()) notifySignalsSafe(high.take(5))
            Result.success()
        } catch (ce: CancellationException) {
            // Don't swallow cancellation — let WorkManager observe it.
            throw ce
        } catch (t: Throwable) {
            Timber.e(t, "scan worker failed")
            Result.retry()
        }
    }

    private fun makeForegroundInfo(text: String): ForegroundInfo {
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
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ForegroundInfo(NOTIF_ID_PROGRESS, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(NOTIF_ID_PROGRESS, notification)
        }
    }

    private fun notifySignalsSafe(signals: List<Signal>) {
        if (!canPostNotifications()) {
            Timber.i("Skipping ${signals.size} signal notifications — POST_NOTIFICATIONS denied")
            return
        }
        val nm = NotificationManagerCompat.from(applicationContext)
        val openAppIntent = PendingIntent.getActivity(
            applicationContext,
            0,
            Intent(applicationContext, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        signals.forEachIndexed { i, sig ->
            runCatching {
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
                nm.notify(NOTIF_ID_SIGNAL_BASE + i, n)
            }.onFailure { Timber.w(it, "notify failed for ${sig.symbol}") }
        }
    }

    private fun canPostNotifications(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = ContextCompat.checkSelfPermission(
                applicationContext,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
            if (!granted) return false
        }
        return NotificationManagerCompat.from(applicationContext).areNotificationsEnabled()
    }

    private fun ensureChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = applicationContext.getSystemService(NotificationManager::class.java) ?: return
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
        const val UNIQUE_NAME_PERIODIC = "apex_periodic_scan"
        const val UNIQUE_NAME_ONESHOT = "apex_oneshot_scan"
    }
}
