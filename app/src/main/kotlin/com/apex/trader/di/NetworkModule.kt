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
        val builder = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(20, TimeUnit.SECONDS)
            .writeTimeout(20, TimeUnit.SECONDS)
            .retryOnConnectionFailure(true)
            .addInterceptor(auth)

        if (BuildConfig.DEBUG) {
            val log = HttpLoggingInterceptor().apply { level = HttpLoggingInterceptor.Level.BASIC }
            builder.addInterceptor(log)
        }
        return builder.build()
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
