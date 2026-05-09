import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/theme.dart';
import '../../providers.dart';

/// Wraps [child] behind a one-shot biometric prompt when the user has the
/// lock enabled in Settings AND the device actually supports it. If anything
/// goes wrong (no enrolled biometrics, plugin fails, disabled in settings),
/// we just show [child] — never crash the activity.
class BiometricGate extends ConsumerStatefulWidget {
  const BiometricGate({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<BiometricGate> createState() => _BiometricGateState();
}

class _BiometricGateState extends ConsumerState<BiometricGate> {
  bool _unlocked = false;
  bool _attempted = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAuth());
  }

  Future<void> _maybeAuth() async {
    if (_unlocked) return;
    final settingsAsync = ref.read(settingsProvider);
    final settings = settingsAsync.valueOrNull;
    final shouldLock = settings?.biometricLockEnabled ?? false;
    if (!shouldLock || !Platform.isAndroid) {
      setState(() => _unlocked = true);
      return;
    }
    setState(() => _attempted = true);
    try {
      final auth = LocalAuthentication();
      final supported = await auth.isDeviceSupported();
      final canCheck = await auth.canCheckBiometrics;
      if (!supported || !canCheck) {
        setState(() => _unlocked = true);
        return;
      }
      final ok = await auth.authenticate(
        localizedReason: 'Unlock Apex Trader',
        options: const AuthenticationOptions(
          biometricOnly: false, // allow PIN/pattern fallback
          stickyAuth: true,
        ),
      );
      if (!mounted) return;
      if (ok) {
        setState(() {
          _unlocked = true;
          _error = null;
        });
      } else {
        setState(() => _error = 'Authentication failed');
      }
    } catch (e) {
      // Plugin / OS issue — don't lock the user out of their app.
      debugPrint('BiometricGate: $e');
      if (!mounted) return;
      setState(() {
        _unlocked = true;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // React to settings changes (e.g. user disables lock from inside the gate).
    final settingsAsync = ref.watch(settingsProvider);
    final shouldLock = settingsAsync.valueOrNull?.biometricLockEnabled ?? false;
    if (!shouldLock || _unlocked) return widget.child;

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.fingerprint, color: ApexColors.primary, size: 72),
              const SizedBox(height: 16),
              Text('Locked', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 6),
              const Text(
                'Authenticate with biometrics or device credential to continue.',
                textAlign: TextAlign.center,
                style: TextStyle(color: ApexColors.textMuted),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: ApexColors.highlight)),
              ],
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _attempted = false;
                    _error = null;
                  });
                  _maybeAuth();
                },
                child: Text(_attempted ? 'Try again' : 'Authenticate'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
