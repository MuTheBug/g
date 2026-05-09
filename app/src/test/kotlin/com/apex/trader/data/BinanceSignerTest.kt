package com.apex.trader.data

import com.apex.trader.data.api.interceptor.BinanceSigner
import com.google.common.truth.Truth.assertThat
import org.junit.Test

class BinanceSignerTest {

    /**
     * Reference test vector taken from the Binance Futures API docs:
     *
     * payload  = "symbol=LTCBTC&side=BUY&type=LIMIT&timeInForce=GTC&quantity=1&price=0.1&recvWindow=5000&timestamp=1499827319559"
     * secret   = "NhqPtmdSJYdKjVHjA7PZj4Mge3R5YNiP1e3UZjInClVN65XAbvqqM6A7H5fATj0j"
     * expected = "c8db56825ae71d6d79447849e617115f4a920fa2acdcab2b053c4b2838bd6b71"
     */
    @Test
    fun `binance hmac sha256 reference vector`() {
        val payload = "symbol=LTCBTC&side=BUY&type=LIMIT&timeInForce=GTC&quantity=1&price=0.1&recvWindow=5000&timestamp=1499827319559"
        val secret = "NhqPtmdSJYdKjVHjA7PZj4Mge3R5YNiP1e3UZjInClVN65XAbvqqM6A7H5fATj0j"
        val expected = "c8db56825ae71d6d79447849e617115f4a920fa2acdcab2b053c4b2838bd6b71"
        assertThat(BinanceSigner.sign(payload, secret)).isEqualTo(expected)
    }
}
