package com.apex.trader.presentation.component

import android.graphics.Color as AndroidColor
import android.graphics.Paint
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.apex.trader.data.model.Candle
import com.apex.trader.domain.indicator.Indicators
import com.apex.trader.domain.strategy.Signal
import com.apex.trader.presentation.theme.ApexBear
import com.apex.trader.presentation.theme.ApexBull
import com.apex.trader.presentation.theme.ApexHighlight
import com.apex.trader.presentation.theme.ApexNeutral
import com.apex.trader.presentation.theme.ApexOutline
import com.apex.trader.presentation.theme.ApexPrimary
import com.apex.trader.presentation.theme.ApexTextMuted
import com.github.mikephil.charting.charts.CombinedChart
import com.github.mikephil.charting.components.LimitLine
import com.github.mikephil.charting.components.XAxis
import com.github.mikephil.charting.data.CandleData
import com.github.mikephil.charting.data.CandleDataSet
import com.github.mikephil.charting.data.CandleEntry
import com.github.mikephil.charting.data.CombinedData
import com.github.mikephil.charting.data.Entry
import com.github.mikephil.charting.data.LineData
import com.github.mikephil.charting.data.LineDataSet
import com.github.mikephil.charting.formatter.ValueFormatter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private fun androidx.compose.ui.graphics.Color.toArgb(): Int = AndroidColor.argb(
    (alpha * 255).toInt(), (red * 255).toInt(), (green * 255).toInt(), (blue * 255).toInt()
)

@Composable
fun CandleChart(
    candles: List<Candle>,
    signal: Signal? = null,
    showEma: Boolean = true,
    showBollinger: Boolean = true,
    height: Dp = 320.dp,
    modifier: Modifier = Modifier
) {
    val data = remember(candles, signal, showEma, showBollinger) {
        buildCombinedData(candles, showEma, showBollinger)
    }
    AndroidView(
        modifier = modifier.fillMaxWidth().height(height),
        factory = { ctx ->
            CombinedChart(ctx).apply {
                setBackgroundColor(AndroidColor.TRANSPARENT)
                description.isEnabled = false
                setDrawGridBackground(false)
                setPinchZoom(true)
                setScaleEnabled(true)
                isDragEnabled = true
                setMaxVisibleValueCount(0)
                legend.textColor = ApexTextMuted.toArgb()
                xAxis.apply {
                    position = XAxis.XAxisPosition.BOTTOM
                    textColor = ApexTextMuted.toArgb()
                    gridColor = ApexOutline.toArgb()
                    setDrawGridLines(false)
                    granularity = 1f
                }
                axisLeft.apply {
                    textColor = ApexTextMuted.toArgb()
                    gridColor = ApexOutline.toArgb()
                    setDrawAxisLine(false)
                }
                axisRight.isEnabled = false
            }
        },
        update = { chart ->
            chart.xAxis.valueFormatter = TimeFormatter(candles)
            chart.data = data
            chart.axisLeft.removeAllLimitLines()
            signal?.let { sig ->
                fun ll(price: Double, label: String, color: Int) =
                    LimitLine(price.toFloat(), label).apply {
                        lineColor = color
                        lineWidth = 1.2f
                        textColor = color
                        textSize = 10f
                    }
                chart.axisLeft.addLimitLine(ll(sig.plan.entry, "Entry ${"%.4f".format(sig.plan.entry)}", ApexHighlight.toArgb()))
                chart.axisLeft.addLimitLine(ll(sig.plan.stopLoss, "SL ${"%.4f".format(sig.plan.stopLoss)}", ApexBear.toArgb()))
                chart.axisLeft.addLimitLine(ll(sig.plan.takeProfit1, "TP1", ApexBull.toArgb()))
                chart.axisLeft.addLimitLine(ll(sig.plan.takeProfit2, "TP2", ApexBull.toArgb()))
                chart.axisLeft.addLimitLine(ll(sig.plan.takeProfit3, "TP3", ApexBull.toArgb()))
            }
            chart.notifyDataSetChanged()
            chart.invalidate()
        }
    )
}

private fun buildCombinedData(
    candles: List<Candle>,
    showEma: Boolean,
    showBollinger: Boolean
): CombinedData {
    val combined = CombinedData()
    if (candles.isEmpty()) return combined

    val candleEntries = candles.mapIndexed { i, c ->
        CandleEntry(i.toFloat(), c.high.toFloat(), c.low.toFloat(), c.open.toFloat(), c.close.toFloat())
    }
    val cds = CandleDataSet(candleEntries, "Price").apply {
        decreasingColor = ApexBear.toArgb()
        decreasingPaintStyle = Paint.Style.FILL
        increasingColor = ApexBull.toArgb()
        increasingPaintStyle = Paint.Style.FILL
        neutralColor = ApexNeutral.toArgb()
        shadowColor = ApexTextMuted.toArgb()
        shadowWidth = 0.7f
        setDrawValues(false)
        highLightColor = ApexHighlight.toArgb()
    }
    combined.setData(CandleData(cds))

    val lineSets = mutableListOf<LineDataSet>()
    val closes = candles.map { it.close }
    if (showEma) {
        val ema21 = Indicators.ema(closes, 21)
        val ema50 = Indicators.ema(closes, 50)
        lineSets += lineSet(ema21, "EMA21", ApexHighlight.toArgb())
        lineSets += lineSet(ema50, "EMA50", ApexPrimary.toArgb())
    }
    if (showBollinger) {
        val bb = Indicators.bollinger(closes)
        lineSets += lineSet(bb.upper, "BB Upper", ApexNeutral.toArgb())
        lineSets += lineSet(bb.lower, "BB Lower", ApexNeutral.toArgb())
        lineSets += lineSet(bb.mid, "BB Mid", ApexNeutral.toArgb())
    }
    if (lineSets.isNotEmpty()) {
        val ld = LineData()
        lineSets.forEach { ld.addDataSet(it) }
        combined.setData(ld)
    }
    return combined
}

private fun lineSet(values: DoubleArray, label: String, color: Int): LineDataSet {
    val entries = values.mapIndexedNotNull { i, v ->
        if (v.isNaN()) null else Entry(i.toFloat(), v.toFloat())
    }
    return LineDataSet(entries, label).apply {
        this.color = color
        lineWidth = 1.4f
        setDrawCircles(false)
        setDrawValues(false)
        setDrawFilled(false)
    }
}

private class TimeFormatter(private val candles: List<Candle>) : ValueFormatter() {
    private val fmt = SimpleDateFormat("MM-dd HH:mm", Locale.US)
    override fun getFormattedValue(value: Float): String {
        if (candles.isEmpty()) return ""
        val i = value.toInt().coerceIn(0, candles.size - 1)
        return fmt.format(Date(candles[i].openTime))
    }
}
