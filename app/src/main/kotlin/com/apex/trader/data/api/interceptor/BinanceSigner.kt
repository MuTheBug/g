package com.apex.trader.data.api.interceptor

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

object BinanceSigner {
    private const val ALGORITHM = "HmacSHA256"

    fun sign(payload: String, secret: String): String {
        val mac = Mac.getInstance(ALGORITHM)
        mac.init(SecretKeySpec(secret.toByteArray(Charsets.UTF_8), ALGORITHM))
        val raw = mac.doFinal(payload.toByteArray(Charsets.UTF_8))
        return raw.joinToString("") { "%02x".format(it) }
    }
}
