package com.apex.trader

import io.flutter.embedding.android.FlutterFragmentActivity

/**
 * FlutterFragmentActivity (vs FlutterActivity) is required for the local_auth
 * plugin's BiometricPrompt to attach correctly.
 */
class MainActivity : FlutterFragmentActivity()
