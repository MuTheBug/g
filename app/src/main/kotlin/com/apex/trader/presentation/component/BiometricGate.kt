package com.apex.trader.presentation.component

import android.content.Context
import android.os.Build
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Fingerprint
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import com.apex.trader.presentation.theme.ApexHighlight
import com.apex.trader.presentation.theme.ApexPrimary
import com.apex.trader.presentation.theme.ApexTextMuted

/**
 * Wraps [content] behind a one-shot biometric prompt. If the device has no biometric
 * capability or the user has the lock disabled, [content] is shown immediately.
 *
 * The prompt is launched once and re-invocable via the "Try again" button on failure.
 * MainActivity must extend [FragmentActivity] (ComponentActivity does) for
 * BiometricPrompt to attach.
 */
@Composable
fun BiometricGate(
    enabled: Boolean,
    content: @Composable () -> Unit
) {
    val context = LocalContext.current
    // Recompute initial unlocked state every time `enabled` changes via the keyed remember.
    var unlocked by remember(enabled) {
        mutableStateOf(!enabled || !canAuthenticate(context))
    }
    var error by remember { mutableStateOf<String?>(null) }
    var attemptKey by remember { mutableStateOf(0) }

    if (!enabled || unlocked) {
        content()
        return
    }

    LaunchedEffect(attemptKey) {
        // Wrap the entire prompt setup so a misconfiguration (e.g. unsupported
        // authenticator combo on this OS version) just unlocks the app rather than
        // crashing the activity from an uncaught LaunchedEffect exception.
        try {
            val activity = context.findFragmentActivity() ?: run {
                unlocked = true
                return@LaunchedEffect
            }
            val authenticators = allowedAuthenticators()
            val executor = ContextCompat.getMainExecutor(context)
            val prompt = BiometricPrompt(
                activity,
                executor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                        error = null
                        unlocked = true
                    }
                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        error = errString.toString()
                    }
                    override fun onAuthenticationFailed() {
                        error = "Not recognized — try again"
                    }
                }
            )
            val infoBuilder = BiometricPrompt.PromptInfo.Builder()
                .setTitle("Apex Trader")
                .setSubtitle("Unlock to view your account & trade")
                .setAllowedAuthenticators(authenticators)
            // BiometricPrompt API contract: setNegativeButtonText is only valid (in fact
            // required) when DEVICE_CREDENTIAL is NOT in the allowed authenticators.
            if ((authenticators and BiometricManager.Authenticators.DEVICE_CREDENTIAL) == 0) {
                infoBuilder.setNegativeButtonText("Cancel")
            }
            prompt.authenticate(infoBuilder.build())
        } catch (t: Throwable) {
            // Don't crash if the prompt can't be configured — let the user in and
            // surface the issue inline.
            error = "Biometric unavailable: ${t.message}"
            unlocked = true
        }
    }

    Box(modifier = Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            Icon(
                Icons.Default.Fingerprint,
                contentDescription = null,
                tint = ApexPrimary,
                modifier = Modifier.size(72.dp)
            )
            Spacer(Modifier.height(16.dp))
            Text("Locked", style = MaterialTheme.typography.headlineMedium)
            Spacer(Modifier.height(6.dp))
            Text(
                "Authenticate with biometrics to continue.",
                color = ApexTextMuted,
                textAlign = TextAlign.Center
            )
            error?.let {
                Spacer(Modifier.height(10.dp))
                Text(
                    it,
                    color = ApexHighlight,
                    style = MaterialTheme.typography.bodyMedium,
                    textAlign = TextAlign.Center
                )
            }
            Spacer(Modifier.height(20.dp))
            Button(onClick = { attemptKey += 1 }) { Text("Authenticate") }
        }
    }
}

private fun canAuthenticate(context: Context): Boolean = try {
    val mgr = BiometricManager.from(context)
    mgr.canAuthenticate(allowedAuthenticators()) == BiometricManager.BIOMETRIC_SUCCESS
} catch (t: Throwable) {
    false
}

/**
 * Authenticator combinations have hard restrictions:
 *  - BIOMETRIC_STRONG | BIOMETRIC_WEAK is always invalid.
 *  - BIOMETRIC_STRONG | DEVICE_CREDENTIAL is only legal on API >= 30.
 *  - BIOMETRIC_WEAK | DEVICE_CREDENTIAL is only legal on API >= 30.
 *  - DEVICE_CREDENTIAL alone is only legal on API >= 30.
 *  - Any other combinations throw IllegalArgumentException at PromptInfo build time.
 *
 * We pick the strongest legal combination per API level so the prompt always builds.
 */
private fun allowedAuthenticators(): Int =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        BiometricManager.Authenticators.BIOMETRIC_WEAK or
            BiometricManager.Authenticators.DEVICE_CREDENTIAL
    } else {
        BiometricManager.Authenticators.BIOMETRIC_STRONG
    }

private fun Context.findFragmentActivity(): FragmentActivity? {
    var ctx: Context? = this
    while (ctx is android.content.ContextWrapper) {
        if (ctx is FragmentActivity) return ctx
        ctx = ctx.baseContext
    }
    return null
}
