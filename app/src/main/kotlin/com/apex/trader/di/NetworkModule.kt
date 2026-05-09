package com.apex.trader.di

import com.apex.trader.BuildConfig
import com.apex.trader.data.api.BinanceFuturesApi
import com.apex.trader.data.api.interceptor.BinanceAuthInterceptor
import com.apex.trader.data.local.CredentialsStore
import com.jakewharton.retrofit2.converter.kotlinx.serialization.asConverterFactory
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.logging.HttpLoggingInterceptor
import retrofit2.Retrofit
import java.util.concurrent.TimeUnit
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object NetworkModule {

    private const val PROD = "https://fapi.binance.com"
    private const val TEST = "https://testnet.binancefuture.com"

    @Provides
    @Singleton
    fun provideJson(): Json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        coerceInputValues = true
        isLenient = true
    }

    @Provides
    @Singleton
    fun provideOkHttp(
        credentialsStore: CredentialsStore
    ): OkHttpClient {
        val auth = BinanceAuthInterceptor(credentialsStore)
        val retry = RetryInterceptor(maxRetries = 2)
        val builder = OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            .writeTimeout(15, TimeUnit.SECONDS)
            .callTimeout(20, TimeUnit.SECONDS) // hard deadline per call
            .retryOnConnectionFailure(true)
            .addInterceptor(auth)
            .addInterceptor(retry)

        if (BuildConfig.DEBUG) {
            val log = HttpLoggingInterceptor().apply { level = HttpLoggingInterceptor.Level.BASIC }
            builder.addInterceptor(log)
        }
        return builder.build()
    }

    /**
     * Retries idempotent GETs on transient failures (IOException or 5xx). Skips
     * POST/DELETE because Binance order placement is non-idempotent and a retry
     * could double-submit.
     */
    private class RetryInterceptor(private val maxRetries: Int = 2) : okhttp3.Interceptor {
        override fun intercept(chain: okhttp3.Interceptor.Chain): okhttp3.Response {
            val request = chain.request()
            if (request.method != "GET") return chain.proceed(request)
            var attempt = 0
            var lastError: java.io.IOException? = null
            while (attempt <= maxRetries) {
                try {
                    val response = chain.proceed(request)
                    if (response.code in 500..599 && attempt < maxRetries) {
                        response.close()
                        attempt++
                        Thread.sleep(250L * attempt)
                        continue
                    }
                    return response
                } catch (e: java.io.IOException) {
                    lastError = e
                    if (attempt >= maxRetries) throw e
                    attempt++
                    try { Thread.sleep(250L * attempt) } catch (_: InterruptedException) { throw e }
                }
            }
            throw lastError ?: java.io.IOException("retry exhausted")
        }
    }

    @Provides
    @Singleton
    fun provideRetrofit(
        client: OkHttpClient,
        json: Json,
        credentialsStore: CredentialsStore
    ): Retrofit {
        // Default to production; if user has stored creds with testnet=true switch base.
        val base = if (credentialsStore.snapshot()?.testnet == true) TEST else PROD
        val contentType = "application/json".toMediaType()
        return Retrofit.Builder()
            .baseUrl(base.toHttpUrl())
            .client(client)
            .addConverterFactory(json.asConverterFactory(contentType))
            .build()
    }

    @Provides
    @Singleton
    fun provideBinanceFuturesApi(retrofit: Retrofit): BinanceFuturesApi =
        retrofit.create(BinanceFuturesApi::class.java)
}
