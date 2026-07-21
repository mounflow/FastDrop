import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:fastdrop_mobile/core/providers.dart';
import 'package:fastdrop_mobile/shared/models/qr_payload.dart';
import 'package:fastdrop_mobile/shared/models/device_info.dart';
import 'package:fastdrop_mobile/shared/models/pair_request.dart';

// ---------------------------------------------------------------------------
// Pairing state
// ---------------------------------------------------------------------------

/// Represents the current phase of the pairing flow.
enum PairingPhase {
  /// Camera is active, waiting for a QR code to be detected.
  scanning,

  /// QR code has been detected, parsing the payload.
  detected,

  /// Pair request has been submitted; polling for acceptance.
  polling,

  /// Pairing succeeded — session info has been received and saved.
  paired,

  /// Pairing failed (rejected, expired, network error, invalid QR, etc.).
  error,
}

class PairingState {
  const PairingState({
    this.phase = PairingPhase.scanning,
    this.qrPayload,
    this.requestId,
    this.errorMessage,
    this.pollAttempt = 0,
  });

  final PairingPhase phase;
  final QrPayload? qrPayload;
  final String? requestId;
  final String? errorMessage;
  final int pollAttempt;
}

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

/// Manages the pairing flow: scan QR, submit pair request, poll for result.
class PairingNotifier extends StateNotifier<PairingState> {
  PairingNotifier(this._ref) : super(const PairingState());

  final Ref _ref;

  Timer? _pollTimer;
  static const _pollInterval = Duration(seconds: 2);
  static const _maxPollAttempts = 30; // 60 seconds max

  /// Called when the camera detects a barcode.
  void onBarcodeDetected(String rawValue) {
    if (state.phase != PairingPhase.scanning) return;

    // Parse the QR payload.
    final payload = QrPayload.tryParse(rawValue);
    if (payload == null) {
      state = PairingState(
        phase: PairingPhase.error,
        errorMessage: 'Invalid QR code. Make sure you are scanning a FastDrop QR code from your PC.',
      );
      return;
    }

    // Validate protocol.
    if (payload.protocol != 'fastdrop') {
      state = PairingState(
        phase: PairingPhase.error,
        errorMessage: 'Not a FastDrop QR code. Detected protocol: "${payload.protocol}".',
      );
      return;
    }

    // Validate expiry.
    if (payload.isExpired) {
      state = PairingState(
        phase: PairingPhase.error,
        errorMessage: 'QR code has expired. Generate a new one on your PC.',
      );
      return;
    }

    state = PairingState(
      phase: PairingPhase.detected,
      qrPayload: payload,
    );

    // Immediately start the pairing handshake.
    _submitPairRequest(payload);
  }

  Future<void> _submitPairRequest(QrPayload payload) async {
    final httpClient = _ref.read(httpClientProvider);

    // Probe each candidate base URL (primary first, then altHosts) and
    // use the first one that responds. This handles the common case where
    // the phone is on the PC's mobile hotspot (different subnet from the
    // PC's primary LAN IP).
    final candidates = payload.candidateBaseUrls;
    String? workingBaseUrl;
    Exception? lastError;
    for (final url in candidates) {
      try {
        httpClient.baseUrl = url;
        // Tiny reachability probe: GET /api/v1/health. Cheaper than
        // issuing the real pair-request (which would consume the token).
        await httpClient.get('/api/v1/health');
        workingBaseUrl = url;
        break;
      } catch (e) {
        lastError = e is Exception ? e : Exception(e);
      }
    }
    if (workingBaseUrl == null) {
      state = PairingState(
        phase: PairingPhase.error,
        errorMessage: 'Could not reach the PC at any candidate address. '
            'Tried: ${candidates.join(", ")}. '
            'Last error: $lastError',
      );
      return;
    }
    httpClient.baseUrl = workingBaseUrl;

    try {
      final deviceId = await DeviceIdManager.getDeviceId();

      final requestBody = PairRequestBody(
        pairId: payload.pairId,
        token: payload.token,
        device: DeviceInfo(
          deviceId: deviceId,
          deviceName: 'My Phone',
          platform: 'android',
          appVersion: '1.0.0',
        ),
      );

      final response = await httpClient.post(
        '/api/v1/pair/request',
        body: requestBody.toJson(),
      );

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final pairResponse = PairRequestResponse.fromJson(decoded);

      // Use the working payload (with the reachable host) for all
      // subsequent operations, including session persistence.
      final workingPayload = payload.copyWith(
        workingHost: Uri.parse(workingBaseUrl).host,
      );

      state = PairingState(
        phase: PairingPhase.polling,
        qrPayload: workingPayload,
        requestId: pairResponse.requestId,
      );

      // Begin polling for the result.
      _startPolling(pairResponse.requestId, workingPayload);
    } catch (e) {
      state = PairingState(
        phase: PairingPhase.error,
        errorMessage: 'Failed to submit pair request: $e',
      );
    }
  }

  void _startPolling(String requestId, QrPayload payload) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) async {
      await _pollStatus(requestId, payload);
    });
  }

  Future<void> _pollStatus(String requestId, QrPayload payload) async {
    if (state.phase != PairingPhase.polling) return;

    final newAttempt = state.pollAttempt + 1;
    if (newAttempt > _maxPollAttempts) {
      _stopPolling();
      state = PairingState(
        phase: PairingPhase.error,
        errorMessage: 'Pairing timed out. Please try scanning the QR code again.',
      );
      return;
    }

    try {
      final httpClient = _ref.read(httpClientProvider);
      final response = await httpClient.get(
        '/api/v1/pair/requests/$requestId',
      );

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final pollResponse = PairPollResponse.fromJson(decoded);

      if (pollResponse.isAccepted) {
        _stopPolling();

        final sessionInfo = pollResponse.session!;
        final serverInfo = pollResponse.server!;

        final expiresAt = DateTime.now().add(
          Duration(seconds: sessionInfo.expiresIn),
        );

        // Persist the session.
        final sessionStore = _ref.read(sessionStoreProvider);
        await sessionStore.saveSession(
          sessionId: sessionInfo.sessionId,
          accessToken: sessionInfo.accessToken,
          serverBaseUrl: payload.baseUrl,
          serverName: serverInfo.deviceName,
          deviceName: 'My Phone',
          expiresAt: expiresAt,
        );

        // Configure the HTTP client with session credentials for future calls.
        httpClient.setSession(sessionInfo.sessionId, sessionInfo.accessToken);

        state = PairingState(
          phase: PairingPhase.paired,
          qrPayload: payload,
          requestId: requestId,
        );
      } else if (pollResponse.isRejected) {
        _stopPolling();
        state = PairingState(
          phase: PairingPhase.error,
          errorMessage: 'Pairing was rejected on the PC.',
        );
      } else if (pollResponse.isExpired) {
        _stopPolling();
        state = PairingState(
          phase: PairingPhase.error,
          errorMessage: 'Pair request expired. Generate a new QR code on your PC and try again.',
        );
      } else {
        // Still waiting — update attempt count.
        state = PairingState(
          phase: PairingPhase.polling,
          qrPayload: payload,
          requestId: requestId,
          pollAttempt: newAttempt,
        );
      }
    } catch (e) {
      _stopPolling();
      state = PairingState(
        phase: PairingPhase.error,
        errorMessage: 'Failed to check pairing status: $e',
      );
    }
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Connect to a PC using a manually entered IP address.
  /// Fetches the QR payload from the server and starts the pairing flow.
  Future<void> connectManualIp(String ip, String port) async {
    final baseUrl = 'http://$ip:$port';
    final httpClient = _ref.read(httpClientProvider);
    httpClient.baseUrl = baseUrl;

    try {
      // Fetch the current QR payload from the server.
      final response = await httpClient.get('/api/v1/pair/qr');
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final payload = QrPayload.fromJson(decoded);

      state = PairingState(
        phase: PairingPhase.detected,
        qrPayload: payload,
      );

      _submitPairRequest(payload);
    } catch (e) {
      state = PairingState(
        phase: PairingPhase.error,
        errorMessage: 'Could not reach PC at $ip:$port. '
            'Make sure FastDrop is running on your PC. Error: $e',
      );
    }
  }

  /// Reset back to scanning state (e.g. after an error).
  void resetToScanning() {
    _stopPolling();
    state = const PairingState();
  }

  @override
  void dispose() {
    _stopPolling();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final pairingProvider =
    StateNotifierProvider<PairingNotifier, PairingState>((ref) {
  return PairingNotifier(ref);
});

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

/// The QR-code scanning and pairing screen.
///
/// Uses `mobile_scanner` for continuous QR detection. When a valid FastDrop
/// QR payload is detected, submits a pair request to the server and polls
/// for acceptance.
class PairingScreen extends ConsumerStatefulWidget {
  const PairingScreen({super.key});

  @override
  ConsumerState<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends ConsumerState<PairingScreen> {
  bool _pairedNavigated = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(pairingProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pair with PC'),
      ),
      body: _buildBody(context, ref, state),
    );
  }

  Widget _buildBody(BuildContext context, WidgetRef ref, PairingState state) {
    switch (state.phase) {
      case PairingPhase.scanning:
        return _buildScanningView(context, ref);
      case PairingPhase.detected:
      case PairingPhase.polling:
        return _buildPollingView(context, state);
      case PairingPhase.paired:
        return _buildPairedView(context, state);
      case PairingPhase.error:
        return _buildErrorView(context, ref, state);
    }
  }

  // -- Scanning ---------------------------------------------------------------

  Widget _buildScanningView(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(pairingProvider.notifier);

    return Stack(
      fit: StackFit.expand,
      children: [
        // Camera view.
        MobileScanner(
          onDetect: (capture) {
            final barcode = capture.barcodes.firstOrNull;
            if (barcode?.rawValue != null) {
              notifier.onBarcodeDetected(barcode!.rawValue!);
            }
          },
        ),
        // Overlay with guide frame.
        Column(
          children: [
            const Spacer(),
            // Scan guide text.
            Container(
              color: Colors.black54,
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.qr_code_scanner, size: 48, color: Colors.white),
                  const SizedBox(height: 12),
                  const Text(
                    'Point your camera at the QR code\non your PC screen',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () => _showManualIpDialog(context, notifier),
                    icon: const Icon(Icons.keyboard, size: 18),
                    label: const Text('Enter IP manually'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white54),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _showManualIpDialog(BuildContext context, PairingNotifier notifier) {
    final ipController = TextEditingController();
    final portController = TextEditingController(text: '9527');

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Connect via IP'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ipController,
              decoration: const InputDecoration(
                labelText: 'PC IP address',
                hintText: '192.168.1.100',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: portController,
              decoration: const InputDecoration(
                labelText: 'Port',
                hintText: '9527',
              ),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final ip = ipController.text.trim();
              final port = portController.text.trim();
              Navigator.pop(dialogContext);
              if (ip.isNotEmpty) {
                notifier.connectManualIp(ip, port.isNotEmpty ? port : '9527');
              }
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }

  // -- Polling ----------------------------------------------------------------

  Widget _buildPollingView(BuildContext context, PairingState state) {
    final serverName = state.qrPayload?.serverName ?? 'PC';

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Connecting to $serverName',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            const Text(
              'Waiting for confirmation on your PC...',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 32),
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              'Attempt ${state.pollAttempt}',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  // -- Paired -----------------------------------------------------------------

  Widget _buildPairedView(BuildContext context, PairingState state) {
    final serverName = state.qrPayload?.serverName ?? 'PC';

    // Fire navigation exactly once after the frame is rendered.
    if (!_pairedNavigated) {
      _pairedNavigated = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          Navigator.of(context, rootNavigator: true)
              .pushNamedAndRemoveUntil('/devices', (route) => false);
        }
      });
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, size: 64, color: Colors.green),
            const SizedBox(height: 16),
            Text(
              'Paired with $serverName',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Opening device screen...',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  // -- Error ------------------------------------------------------------------

  Widget _buildErrorView(BuildContext context, WidgetRef ref, PairingState state) {
    final notifier = ref.read(pairingProvider.notifier);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              'Pairing Failed',
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              state.errorMessage ?? 'An unknown error occurred.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: notifier.resetToScanning,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan Again'),
            ),
          ],
        ),
      ),
    );
  }
}
