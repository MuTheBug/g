package com.apex.trader.data.api.interceptor

import com.apex.trader.data.local.CredentialsStore
import okhttp3.Interceptor
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okio.Buffer

/**
 * Adds X-MBX-APIKEY header on requests tagged with [SignedTag].
 *
 * If the request also carries [SecuredTag], the body/query is signed with HMAC-SHA256
 * using the user's secret key and a timestamp + recvWindow are appended automatically.
 *
 * Binance requires the signature to be computed over the *exact* string sent on the wire
 * (concatenation of query + body, in that order). We do that here.
 */
class BinanceAuthInterceptor(
    private val credentialsStore: CredentialsStore,
    private val timeProvider: () -> Long = { System.currentTimeMillis() },
    private val recvWindowMs: Long = 5_000L
) : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        val original = chain.request()
        val signed = original.tag(SignedTag::class.java) != null
        if (!signed) return chain.proceed(original)

        val creds = credentialsStore.snapshot()
            ?: error("Binance API credentials are not configured")

        val builder = original.newBuilder().header("X-MBX-APIKEY", creds.apiKey)
        val secured = original.tag(SecuredTag::class.java) != null
        val request = if (secured) signRequest(original, builder, creds.apiSecret) else builder.build()
        return chain.proceed(request)
    }

    private fun signRequest(
        original: Request,
        builder: Request.Builder,
        secret: String
    ): Request {
        val timestamp = timeProvider()
        val urlBuilder = original.url.newBuilder()
            .addQueryParameter("timestamp", timestamp.toString())
            .addQueryParameter("recvWindow", recvWindowMs.toString())

        val withTimeUrl = urlBuilder.build()
        val queryString = withTimeUrl.encodedQuery.orEmpty()

        val bodyString: String = original.body?.let { body ->
            val buf = Buffer()
            body.writeTo(buf)
            buf.readUtf8()
        }.orEmpty()

        val payload = queryString + bodyString
        val signature = BinanceSigner.sign(payload, secret)

        val finalUrl = withTimeUrl.newBuilder()
            .addQueryParameter("signature", signature)
            .build()

        // Body is preserved (signature stays in the query portion)
        val finalBody: RequestBody? = if (original.body != null) {
            val ct = original.body!!.contentType()
            bodyString.toRequestBody(ct)
        } else null

        return builder.url(finalUrl).method(original.method, finalBody).build()
    }
}

/** Marker tag — request needs the API key header. */
object SignedTag

/** Marker tag — request needs HMAC signing (implies SignedTag). */
object SecuredTag
