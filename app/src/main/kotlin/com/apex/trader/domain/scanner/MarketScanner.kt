package com.apex.trader.domain.scanner

import com.apex.trader.data.api.dto.TickerDto
import com.apex.trader.data.model.Timeframe
import com.apex.trader.data.repository.MarketRepository
import com.apex.trader.data.repository.SettingsRepository
import com.apex.trader.domain.strategy.ApexConfluenceStrategy
import com.apex.trader.domain.strategy.Signal
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
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
     * Scans up to [SettingsRepository.AppSettings.scanLimit] of the highest-volume USDT
     * perp symbols and returns the high-confidence signals sorted by confidence desc.
     *
     * Runs evaluation with bounded parallelism (default 6) to avoid hammering the
     * Binance REST endpoints — `/fapi/v1/klines` is weight 5 and we issue 3 per symbol.
     */
    suspend fun scan(
        progress: (ScanProgress) -> Unit = {},
        parallelism: Int = 6
    ): List<Signal> = coroutineScope {
        val settings = settingsRepository.settings.first()
        val tickers = marketRepository.get24hTickers()
            .filter { it.symbol.endsWith("USDT") }
            .filter { it.symbol !in settings.excludedSymbols }

        val symbols = pickSymbols(tickers, settings.scanLimit, settings.watchlist)
        val htf = Timeframe.fromCode(settings.htfTimeframe)
        val mtf = Timeframe.fromCode(settings.mtfTimeframe)
        val ltf = Timeframe.fromCode(settings.ltfTimeframe)

        val sem = Semaphore(parallelism)
        val signals = mutableListOf<Signal>()
        var processed = 0
        var errors = 0

        val deferreds = symbols.map { symbol ->
            async(Dispatchers.IO) {
                sem.withPermit {
                    val signal = runCatching { evaluateOne(symbol, htf, mtf, ltf) }
                        .onFailure { Timber.w(it, "scan failed for $symbol") }
                        .getOrNull()
                    synchronized(signals) {
                        processed++
                        if (signal != null) signals += signal
                        if (signal == null) {
                            // Don't double-count successes as errors.
                        }
                        progress(ScanProgress(processed, symbols.size, symbol, signals.toList().sortedByDescending { it.confidence }, errors))
                    }
                    signal
                }
            }
        }
        deferreds.awaitAll()
        synchronized(signals) {
            signals.toList().sortedByDescending { it.confidence }
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
        // Drop the (still-forming) latest candle so the strategy sees only closed bars.
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
        // Always include watchlist; fill the rest with top quote-volume symbols.
        val byVolumeDesc = tickers.sortedByDescending { it.quoteVolume.toDoubleOrNull() ?: 0.0 }
        val watch = watchlist.filter { wl -> tickers.any { it.symbol == wl } }
        val rest = byVolumeDesc.map { it.symbol }.filter { it !in watch }
        val take = (limit - watch.size).coerceAtLeast(0)
        return (watch + rest.take(take)).distinct()
    }
}

