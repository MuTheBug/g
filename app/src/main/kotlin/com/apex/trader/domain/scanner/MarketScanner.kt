package com.apex.trader.domain.scanner

import com.apex.trader.data.api.dto.TickerDto
import com.apex.trader.data.model.Timeframe
import com.apex.trader.data.repository.MarketRepository
import com.apex.trader.data.repository.SettingsRepository
import com.apex.trader.domain.strategy.ApexConfluenceStrategy
import com.apex.trader.domain.strategy.Signal
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import timber.log.Timber
import javax.inject.Inject
import javax.inject.Singleton

data class ScanProgress(
    val processed: Int,
    val total: Int,
    val current: String?,
    val signals: List<Signal>,
    val errors: Int
)

@Singleton
class MarketScanner @Inject constructor(
    private val marketRepository: MarketRepository,
    private val settingsRepository: SettingsRepository,
    private val strategy: ApexConfluenceStrategy
) {

    /**
     * Scans the configured number of symbols (default 30, top USDT-M perps by volume
     * plus the user watchlist) and returns high-confidence signals sorted by
     * confidence descending.
     *
     * Reliability features:
     * - Bounded parallelism (default 3) to keep request load low and avoid
     *   tripping Binance rate limits or saturating the device's TCP pool.
     * - Per-symbol [withTimeout] of 20s so a single stuck request can never
     *   stall the entire scan.
     * - Re-throws [CancellationException] so screen exit cleanly tears the
     *   scan down (previously runCatching swallowed cancellation).
     * - Progress callback invoked OUTSIDE the lock; a slow / faulty subscriber
     *   can't block other scanning coroutines.
     */
    suspend fun scan(
        progress: (ScanProgress) -> Unit = {},
        parallelism: Int = 3,
        perSymbolTimeoutMs: Long = 20_000L
    ): List<Signal> = coroutineScope {
        val settings = settingsRepository.settings.first()
        val tickers = try {
            marketRepository.get24hTickers()
                .filter { it.symbol.endsWith("USDT") }
                .filter { it.symbol !in settings.excludedSymbols }
        } catch (ce: CancellationException) {
            throw ce
        } catch (t: Throwable) {
            Timber.e(t, "ticker fetch failed; aborting scan")
            return@coroutineScope emptyList()
        }
        if (tickers.isEmpty()) return@coroutineScope emptyList()

        val symbols = pickSymbols(tickers, settings.scanLimit, settings.watchlist)
        val htf = Timeframe.fromCode(settings.htfTimeframe)
        val mtf = Timeframe.fromCode(settings.mtfTimeframe)
        val ltf = Timeframe.fromCode(settings.ltfTimeframe)

        val sem = Semaphore(parallelism)
        val mutex = Mutex()
        val signals = mutableListOf<Signal>()
        var processed = 0
        var errors = 0

        val deferreds = symbols.map { symbol ->
            async(Dispatchers.IO) {
                sem.withPermit {
                    val signal = try {
                        withTimeout(perSymbolTimeoutMs) {
                            evaluateOne(symbol, htf, mtf, ltf)
                        }
                    } catch (timeout: TimeoutCancellationException) {
                        Timber.w("scan timed out for $symbol after ${perSymbolTimeoutMs}ms")
                        null
                    } catch (ce: CancellationException) {
                        // Outer scope cancellation — propagate so structured concurrency
                        // unwinds cleanly. (TimeoutCancellationException is handled above.)
                        throw ce
                    } catch (t: Throwable) {
                        Timber.w(t, "scan failed for $symbol")
                        null
                    }
                    val snapshot = mutex.withLock {
                        processed++
                        if (signal != null) signals += signal
                        else errors++
                        ScanProgress(
                            processed = processed,
                            total = symbols.size,
                            current = symbol,
                            signals = signals.sortedByDescending { it.confidence },
                            errors = errors
                        )
                    }
                    runCatching { progress(snapshot) }
                        .onFailure { Timber.w(it, "progress callback threw") }
                    signal
                }
            }
        }
        deferreds.awaitAll()
        mutex.withLock {
            signals.sortedByDescending { it.confidence }
        }
    }

    suspend fun evaluateOne(
        symbol: String,
        htf: Timeframe,
        mtf: Timeframe,
        ltf: Timeframe
    ): Signal? = withContext(Dispatchers.IO) {
        val htfCandles = marketRepository.getCandles(symbol, htf, 250)
        val mtfCandles = marketRepository.getCandles(symbol, mtf, 250)
        val ltfCandles = marketRepository.getCandles(symbol, ltf, 200)
        val htfClosed = htfCandles.dropLast(1)
        val mtfClosed = mtfCandles.dropLast(1)
        val ltfClosed = ltfCandles.dropLast(1)
        strategy.evaluate(symbol, htfClosed, mtfClosed, ltfClosed)
    }

    private fun pickSymbols(
        tickers: List<TickerDto>,
        limit: Int,
        watchlist: Set<String>
    ): List<String> {
        val byVolumeDesc = tickers.sortedByDescending { it.quoteVolume.toDoubleOrNull() ?: 0.0 }
        val watch = watchlist.filter { wl -> tickers.any { it.symbol == wl } }
        val rest = byVolumeDesc.map { it.symbol }.filter { it !in watch }
        val take = (limit - watch.size).coerceAtLeast(0)
        return (watch + rest.take(take)).distinct()
    }
}
