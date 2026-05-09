package com.apex.trader.domain.strategy

enum class SignalSide { LONG, SHORT }

enum class MarketRegime { TRENDING, RANGING, TRANSITION }

/**
 * Decomposed reason for a signal — surfaced in the UI so users can see *why* the
 * strategy fired. Each component contributes a positive or negative weight to the
 * overall confidence score.
 */
data class SignalReason(
    val label: String,
    val detail: String,
    val weight: Double, // positive contributes for, negative against
    val passed: Boolean
)

data class TradePlan(
    val entry: Double,
    val stopLoss: Double,
    val takeProfit1: Double,
    val takeProfit2: Double,
    val takeProfit3: Double,
    val riskRewardR1: Double,
    val riskRewardR2: Double,
    val riskRewardR3: Double,
    val atr: Double
)

data class Signal(
    val symbol: String,
    val side: SignalSide,
    val regime: MarketRegime,
    val confidence: Int, // 0..100
    val plan: TradePlan,
    val reasons: List<SignalReason>,
    val htfTrendUp: Boolean,
    val mtfTrendUp: Boolean,
    val createdAt: Long,
    val price: Double,
    val volumeSurge: Double,
    val adx: Double,
    val rsi: Double
) {
    val reasonsPassed: List<SignalReason> get() = reasons.filter { it.passed }
    val reasonsFailed: List<SignalReason> get() = reasons.filterNot { it.passed }
}
