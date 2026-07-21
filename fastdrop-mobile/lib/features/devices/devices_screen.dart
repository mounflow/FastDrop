import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fastdrop_mobile/core/network/http_client.dart';
import 'package:fastdrop_mobile/core/network/ws_client.dart';
import 'package:fastdrop_mobile/core/storage/session_store.dart';
import 'package:fastdrop_mobile/core/providers.dart';
import 'package:fastdrop_mobile/features/transfer/transfer_service.dart';
import 'package:fastdrop_mobile/shared/models/transfer.dart';
import 'package:fastdrop_mobile/shared/widgets/status_badge.dart';

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// An incoming file offer from the PC (server_to_client).
class IncomingOffer {
  const IncomingOffer({
    required this.transferId,
    required this.offerId,
    required this.deviceName,
    required this.files,
  });

  final String transferId;
  final String offerId;
  final String deviceName;
  final List<OfferFile> files;

  int get totalBytes => files.fold(0, (sum, f) => sum + f.size);
}

class OfferFile {
  const OfferFile({
    required this.fileId,
    required this.name,
    required this.size,
    this.mimeType,
    this.sha256,
  });

  final String fileId;
  final String name;
  final int size;
  final String? mimeType;
  final String? sha256;
}

/// Tracks a single file download in progress.
class ActiveDownload {
  ActiveDownload({
    required this.transferId,
    required this.fileId,
    required this.fileName,
    required this.totalBytes,
    this.transferredBytes = 0,
    this.status = 'downloading',
    this.error,
  });

  final String transferId;
  final String fileId;
  final String fileName;
  final int totalBytes;
  int transferredBytes;
  String status; // downloading | completed | failed
  String? error;

  double get progress =>
      totalBytes > 0 ? transferredBytes / totalBytes : 0.0;
}

// ---------------------------------------------------------------------------
// Connection state
// ---------------------------------------------------------------------------

/// Describes the current WebSocket connection status.
enum ConnectionStatus {
  connecting,
  connected,
  disconnected,
  error,
}

class DeviceConnectionState {
  const DeviceConnectionState({
    this.connectionStatus = ConnectionStatus.disconnected,
    this.sessionData,
    this.errorMessage,
    this.incomingOffers = const [],
    this.activeDownloads = const [],
    this.sessionRevoked = false,
  });

  final ConnectionStatus connectionStatus;
  final SessionData? sessionData;
  final String? errorMessage;
  final List<IncomingOffer> incomingOffers;
  final List<ActiveDownload> activeDownloads;
  final bool sessionRevoked;

  bool get isConnected => connectionStatus == ConnectionStatus.connected;

  DeviceConnectionState copyWith({
    ConnectionStatus? connectionStatus,
    SessionData? sessionData,
    String? errorMessage,
    List<IncomingOffer>? incomingOffers,
    List<ActiveDownload>? activeDownloads,
    bool? sessionRevoked,
  }) {
    return DeviceConnectionState(
      connectionStatus: connectionStatus ?? this.connectionStatus,
      sessionData: sessionData ?? this.sessionData,
      errorMessage: errorMessage,
      incomingOffers: incomingOffers ?? this.incomingOffers,
      activeDownloads: activeDownloads ?? this.activeDownloads,
      sessionRevoked: sessionRevoked ?? this.sessionRevoked,
    );
  }
}

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

/// Manages the device screen: loads session, connects WebSocket, tracks
/// connection status, handles incoming file offers, and drives downloads.
class DeviceConnectionNotifier extends StateNotifier<DeviceConnectionState> {
  DeviceConnectionNotifier(this._ref) : super(const DeviceConnectionState());

  final Ref _ref;

  bool _initialized = false;
  TransferService? _transferService;

  /// Transfer IDs that the user has explicitly cancelled.
  final Set<String> _cancelledTransfers = {};

  /// Initialize: load session, configure HTTP client, connect WS.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    final session = await _ref.read(sessionStoreProvider).loadSession();

    if (session == null) {
      state = const DeviceConnectionState(
        connectionStatus: ConnectionStatus.error,
        errorMessage: 'No saved session. Please pair with your PC first.',
      );
      return;
    }

    if (session.isExpired) {
      state = const DeviceConnectionState(
        connectionStatus: ConnectionStatus.error,
        errorMessage: 'Session expired. Please pair with your PC again.',
      );
      return;
    }

    state = DeviceConnectionState(
      connectionStatus: ConnectionStatus.connecting,
      sessionData: session,
    );

    // Configure HTTP client.
    final httpClient = _ref.read(httpClientProvider);
    httpClient.baseUrl = session.serverBaseUrl;
    httpClient.setSession(session.sessionId, session.accessToken);

    // Create TransferService for downloads.
    final wsClient = _ref.read(wsClientProvider);
    _transferService = TransferService(
      httpClient: httpClient,
      wsClient: wsClient,
      onProgress: _onDownloadProgress,
      onStateChange: _onDownloadStateChange,
    );

    // Configure and connect WS client.
    wsClient.baseUrl = session.serverBaseUrl;
    wsClient.setSession(session.sessionId, session.accessToken);

    wsClient
      ..onConnected = _onWsConnected
      ..onDisconnected = _onWsDisconnected
      ..onMessage = _onWsMessage
      ..onAuthFailed = _onWsAuthFailed;

    try {
      await wsClient.connect();
    } catch (e) {
      state = state.copyWith(
        connectionStatus: ConnectionStatus.error,
        errorMessage: 'Failed to connect: $e',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // WS callbacks
  // ---------------------------------------------------------------------------

  void _onWsConnected() {
    if (!mounted) return;
    state = state.copyWith(connectionStatus: ConnectionStatus.connected);
  }

  void _onWsDisconnected() {
    if (!mounted) return;
    state = state.copyWith(connectionStatus: ConnectionStatus.disconnected);
  }

  void _onWsAuthFailed() {
    if (!mounted) return;
    // Session was revoked (e.g. server restarted) — trigger navigation
    // to the pairing screen.
    state = state.copyWith(
      sessionRevoked: true,
      connectionStatus: ConnectionStatus.disconnected,
      incomingOffers: [],
    );
  }

  void _onWsMessage(Map<String, dynamic> message) {
    if (!mounted) return;

    final type = message['type'] as String?;
    final payload = message['payload'] as Map<String, dynamic>? ?? {};

    switch (type) {
      case 'file.offer':
        _handleIncomingOffer(payload);
        break;
      case 'transfer.started':
        // Transfer began — no UI change needed beyond what progress provides.
        break;
      case 'transfer.progress':
        _handleTransferProgress(payload);
        break;
      case 'transfer.completed':
        _handleTransferCompleted(payload);
        break;
      case 'transfer.failed':
        _handleTransferFailed(payload);
        break;
      case 'transfer.cancelled':
        _handleTransferCancelled(payload);
        break;
      case 'transfer.paused':
        _handleTransferPaused(payload);
        break;
      case 'transfer.resume':
        _handleTransferResume(payload);
        break;
      case 'session.revoked':
        _handleSessionRevoked();
        break;
      case 'error':
        // Server-side error — log but don't crash.
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Incoming offer handling
  // ---------------------------------------------------------------------------

  void _handleIncomingOffer(Map<String, dynamic> payload) {
    final transferId = payload['transferId'] as String? ?? '';
    final offerId = payload['offerId'] as String? ?? '';
    final deviceName = payload['deviceName'] as String? ?? 'PC';
    final filesRaw = payload['files'] as List<dynamic>? ?? [];

    final files = filesRaw.map((f) {
      final m = f as Map<String, dynamic>;
      return OfferFile(
        fileId: m['fileId'] as String? ?? '',
        name: m['name'] as String? ?? 'unknown',
        size: m['size'] as int? ?? 0,
        mimeType: m['mimeType'] as String?,
        sha256: m['sha256'] as String?,
      );
    }).toList();

    final offer = IncomingOffer(
      transferId: transferId,
      offerId: offerId,
      deviceName: deviceName,
      files: files,
    );

    state = state.copyWith(
      incomingOffers: [...state.incomingOffers, offer],
    );
  }

  /// Accept an incoming offer: notify the server, then download each file
  /// with retry (max 3 attempts, exponential backoff).
  Future<void> acceptOffer(IncomingOffer offer) async {
    // Remove from pending offers.
    _cancelledTransfers.remove(offer.transferId);
    state = state.copyWith(
      incomingOffers: state.incomingOffers
          .where((o) => o.transferId != offer.transferId)
          .toList(),
    );

    // Send file.offer.accept via WS.
    final wsClient = _ref.read(wsClientProvider);
    wsClient.send({
      'version': 1,
      'type': 'file.offer.accept',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': {'offerId': offer.transferId},
    });

    // Create download tracking entries.
    final downloads = [...state.activeDownloads];
    for (final f in offer.files) {
      downloads.add(ActiveDownload(
        transferId: offer.transferId,
        fileId: f.fileId,
        fileName: f.name,
        totalBytes: f.size,
      ));
    }
    state = state.copyWith(activeDownloads: downloads);

    // Download each file with retry.
    const maxRetries = 3;
    const backoffMs = [1000, 2000, 4000];
    for (final f in offer.files) {
      if (_cancelledTransfers.contains(offer.transferId)) return;

      Exception? lastError;
      for (int attempt = 0; attempt < maxRetries; attempt++) {
        if (_cancelledTransfers.contains(offer.transferId)) return;
        try {
          await _transferService?.downloadFile(
            transferId: offer.transferId,
            fileId: f.fileId,
            fileName: f.name,
            totalBytes: f.size,
            expectedSha256: f.sha256 ?? '',
          );
          _updateDownload(offer.transferId, f.fileId,
              status: 'completed');
          lastError = null;
          break;
        } catch (e) {
          lastError = e is Exception ? e : Exception(e.toString());
          if (attempt < maxRetries - 1) {
            await Future.delayed(
                Duration(milliseconds: backoffMs[attempt]));
          }
        }
      }
      if (lastError != null) {
        _updateDownload(offer.transferId, f.fileId,
            status: 'failed', error: lastError.toString());
      }
    }
  }

  /// Cancel an in-progress download.
  void cancelDownload(String transferId) {
    _cancelledTransfers.add(transferId);
    _transferService?.cancelTransfer(transferId);
    state = state.copyWith(
      activeDownloads: state.activeDownloads
          .where((d) => d.transferId != transferId)
          .toList(),
    );
  }

  /// Reject an incoming offer.
  void rejectOffer(IncomingOffer offer) {
    state = state.copyWith(
      incomingOffers: state.incomingOffers
          .where((o) => o.transferId != offer.transferId)
          .toList(),
    );

    final wsClient = _ref.read(wsClientProvider);
    wsClient.send({
      'version': 1,
      'type': 'file.offer.reject',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': {
        'offerId': offer.transferId,
        'reason': 'user_rejected',
      },
    });
  }

  // ---------------------------------------------------------------------------
  // Download progress / state
  // ---------------------------------------------------------------------------

  void _onDownloadProgress(
      String transferId, String fileId, TransferProgress progress) {
    if (!mounted) return;
    _updateDownload(transferId, fileId,
        transferredBytes: progress.bytesTransferred);
  }

  void _onDownloadStateChange(String transferId, String status,
      {String? errorCode, String? errorMessage}) {
    if (!mounted) return;
    if (status == 'completed' || status == 'failed') {
      // Update all downloads for this transfer.
      final downloads = state.activeDownloads.map((d) {
        if (d.transferId == transferId && d.status == 'downloading') {
          d.status = status;
          d.error = errorMessage;
        }
        return d;
      }).toList();
      state = state.copyWith(activeDownloads: downloads);
    }
  }

  void _updateDownload(String transferId, String fileId,
      {int? transferredBytes, String? status, String? error}) {
    if (!mounted) return;
    final downloads = state.activeDownloads.map((d) {
      if (d.transferId == transferId && d.fileId == fileId) {
        if (transferredBytes != null) d.transferredBytes = transferredBytes;
        if (status != null) d.status = status;
        if (error != null) d.error = error;
      }
      return d;
    }).toList();
    state = state.copyWith(activeDownloads: downloads);
  }

  // ---------------------------------------------------------------------------
  // Transfer WS event handlers
  // ---------------------------------------------------------------------------

  void _handleTransferProgress(Map<String, dynamic> payload) {
    final transferId = payload['transferId'] as String? ?? '';
    final fileId = payload['fileId'] as String? ?? '';
    final transferred = payload['transferredBytes'] as int? ??
        payload['bytesTransferred'] as int? ?? 0;
    _updateDownload(transferId, fileId, transferredBytes: transferred);
  }

  void _handleTransferCompleted(Map<String, dynamic> payload) {
    final transferId = payload['transferId'] as String? ?? '';
    final downloads = state.activeDownloads.map((d) {
      if (d.transferId == transferId) d.status = 'completed';
      return d;
    }).toList();
    state = state.copyWith(activeDownloads: downloads);
  }

  void _handleTransferFailed(Map<String, dynamic> payload) {
    final transferId = payload['transferId'] as String? ?? '';
    final error = payload['error']?.toString() ?? 'Transfer failed';
    final downloads = state.activeDownloads.map((d) {
      if (d.transferId == transferId) {
        d.status = 'failed';
        d.error = error;
      }
      return d;
    }).toList();
    state = state.copyWith(activeDownloads: downloads);
  }

  void _handleTransferPaused(Map<String, dynamic> payload) {
    final transferId = payload['transferId'] as String? ?? '';
    final downloads = state.activeDownloads.map((d) {
      if (d.transferId == transferId && d.status == 'downloading') {
        d.status = 'paused';
      }
      return d;
    }).toList();
    state = state.copyWith(activeDownloads: downloads);
  }

  void _handleTransferResume(Map<String, dynamic> payload) {
    final transferId = payload['transferId'] as String? ?? '';
    final downloads = state.activeDownloads.map((d) {
      if (d.transferId == transferId && d.status == 'paused') {
        d.status = 'downloading';
      }
      return d;
    }).toList();
    state = state.copyWith(activeDownloads: downloads);
  }

  void _handleTransferCancelled(Map<String, dynamic> payload) {
    final transferId = payload['transferId'] as String? ?? '';
    final downloads = state.activeDownloads
        .where((d) => d.transferId != transferId)
        .toList();
    state = state.copyWith(activeDownloads: downloads);
  }

  void _handleSessionRevoked() {
    state = state.copyWith(
      sessionRevoked: true,
      connectionStatus: ConnectionStatus.disconnected,
      incomingOffers: [],
    );
  }

  /// Clear completed/failed downloads from the list.
  void clearFinishedDownloads() {
    state = state.copyWith(
      activeDownloads: state.activeDownloads
          .where((d) => d.status == 'downloading')
          .toList(),
    );
  }

  @override
  void dispose() {
    _cancelledTransfers.clear();
    _transferService?.dispose();
    try {
      _ref.read(wsClientProvider).disconnect();
    } catch (_) {}
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final deviceConnectionProvider =
    StateNotifierProvider<DeviceConnectionNotifier, DeviceConnectionState>((ref) {
  return DeviceConnectionNotifier(ref);
});

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

/// Displays the paired PC with connection status and navigation options.
///
/// Phase 1: shows the single paired PC. Phase 2 will also show mDNS-discovered
/// devices.
class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  @override
  void initState() {
    super.initState();
    // Initialize after the first frame to ensure providers are available.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(deviceConnectionProvider.notifier).init();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(deviceConnectionProvider);

    // Navigate to pairing if session was revoked.
    if (state.sessionRevoked) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Session revoked by PC')),
          );
          Navigator.of(context).pushNamedAndRemoveUntil(
              '/pairing', (route) => false);
        }
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('FastDrop'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'History',
            onPressed: () => Navigator.of(context).pushNamed('/history'),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
          ),
        ],
      ),
      body: _buildBody(context, state),
    );
  }

  Widget _buildBody(BuildContext context, DeviceConnectionState state) {
    if (state.sessionData == null) {
      return _buildNoSession(context, state.errorMessage);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Server info card.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.computer, size: 48),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          state.sessionData!.serverName ?? 'PC',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          state.sessionData!.serverBaseUrl,
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _connectionBadge(state.connectionStatus),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Send Files button.
          ElevatedButton.icon(
            onPressed: state.isConnected ? _onSendFiles : null,
            icon: const Icon(Icons.file_upload),
            label: const Text('Send Files'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),

          // Incoming offers section.
          if (state.incomingOffers.isNotEmpty) ...[
            const SizedBox(height: 24),
            _buildIncomingOffers(context, state),
          ],

          // Active downloads section.
          if (state.activeDownloads.isNotEmpty) ...[
            const SizedBox(height: 24),
            _buildActiveDownloads(context, state),
          ],

          const SizedBox(height: 24),

          // Tip.
          Center(
            child: Text(
              'Send files to your paired PC over the local network.\nNo cloud, no accounts, no limits.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  // -- Incoming offers UI -------------------------------------------------------

  Widget _buildIncomingOffers(
      BuildContext context, DeviceConnectionState state) {
    final notifier = ref.read(deviceConnectionProvider.notifier);
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Incoming Files', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        ...state.incomingOffers.map((offer) => Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'From: ${offer.deviceName}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '${offer.files.length} file(s)',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ...offer.files.map((f) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            '${f.name}  (${_formatBytes(f.size)})',
                            style: theme.textTheme.bodySmall,
                          ),
                        )),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => notifier.rejectOffer(offer),
                          child: const Text('Reject',
                              style: TextStyle(color: Colors.red)),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () => notifier.acceptOffer(offer),
                          child: const Text('Accept'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            )),
      ],
    );
  }

  // -- Active downloads UI ------------------------------------------------------

  Widget _buildActiveDownloads(
      BuildContext context, DeviceConnectionState state) {
    final notifier = ref.read(deviceConnectionProvider.notifier);
    final theme = Theme.of(context);
    final hasFinished =
        state.activeDownloads.any((d) => d.status != 'downloading');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Downloads', style: theme.textTheme.titleSmall),
            if (hasFinished)
              TextButton(
                onPressed: notifier.clearFinishedDownloads,
                child: const Text('Clear finished'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        ...state.activeDownloads.map((d) => Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            d.fileName,
                            style: theme.textTheme.bodyMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        _downloadStatusChip(d),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: d.progress,
                        minHeight: 6,
                        backgroundColor: Colors.grey.shade200,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          d.status == 'failed'
                              ? Colors.red
                              : d.status == 'completed'
                                  ? Colors.green
                                  : theme.colorScheme.primary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_formatBytes(d.transferredBytes)} / ${_formatBytes(d.totalBytes)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.grey,
                      ),
                    ),
                    if (d.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          d.error!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.red,
                            fontSize: 11,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (d.status == 'downloading')
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton.icon(
                              onPressed: () =>
                                  notifier.cancelDownload(d.transferId),
                              icon: const Icon(Icons.cancel, size: 16),
                              label: const Text('Cancel'),
                              style: TextButton.styleFrom(
                                  foregroundColor: Colors.red),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            )),
      ],
    );
  }

  Widget _downloadStatusChip(ActiveDownload d) {
    Color color;
    String label;
    switch (d.status) {
      case 'completed':
        color = Colors.green;
        label = 'Done';
        break;
      case 'failed':
        color = Colors.red;
        label = 'Failed';
        break;
      default:
        color = Colors.blue;
        label = '${(d.progress * 100).toInt()}%';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  // -- Shared widgets -----------------------------------------------------------

  Widget _buildNoSession(BuildContext context, String? errorMessage) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.computer, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              errorMessage ?? 'No devices paired yet.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => Navigator.of(context).pushReplacementNamed('/pairing'),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Pair with PC'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _connectionBadge(ConnectionStatus status) {
    switch (status) {
      case ConnectionStatus.connected:
        return const StatusBadge(label: 'Connected', color: Colors.green);
      case ConnectionStatus.connecting:
        return const StatusBadge(label: 'Connecting...', color: Colors.orange);
      case ConnectionStatus.disconnected:
        return const StatusBadge(label: 'Disconnected', color: Colors.red);
      case ConnectionStatus.error:
        return const StatusBadge(label: 'Error', color: Colors.red);
    }
  }

  void _onSendFiles() {
    Navigator.of(context).pushNamed('/file-picker');
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
