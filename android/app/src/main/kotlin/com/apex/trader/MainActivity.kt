package com.apex.trader

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * FlutterFragmentActivity (vs FlutterActivity) is required by the local_auth
 * plugin's BiometricPrompt to attach correctly. We also expose a tiny
 * `apex_trader/host` channel so the Dart side can call `moveTaskToBack` —
 * this implements the Termux-style minimize: the activity goes to background
 * but the Dart isolate and our persistent notification stay alive.
 */
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "apex_trader/host")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "moveTaskToBack" -> {
                        moveTaskToBack(true)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
