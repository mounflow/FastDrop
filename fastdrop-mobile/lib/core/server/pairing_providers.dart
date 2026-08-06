import 'package:fastdrop_mobile/core/server/pairing_handler.dart';
import 'package:fastdrop_mobile/core/server/ws_server.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Riverpod state for incoming pair requests that need user confirmation.
///
/// The embedded server's [PairingHandler] pushes new requests here via
/// [addRequest]; the UI layer watches this provider and shows a
/// confirmation dialog.
class PendingPairRequestsNotifier
    extends StateNotifier<List<ServerPairRequest>> {
  PendingPairRequestsNotifier() : super([]);

  void addRequest(ServerPairRequest request) {
    state = [...state, request];
  }

  void updateStatus(String requestId, String status) {
    state = state.map((r) {
      if (r.requestId == requestId) {
        r.status = status;
      }
      return r;
    }).toList();
    // Remove resolved requests after a short delay.
    _cleanup();
  }

  void removeRequest(String requestId) {
    state = state.where((r) => r.requestId != requestId).toList();
  }

  void _cleanup() {
    state = state.where((r) => r.status == 'waiting_confirmation').toList();
  }

  void clear() => state = [];
}

/// Provider for pending pair requests awaiting user confirmation.
final pendingPairRequestsProvider =
    StateNotifierProvider<PendingPairRequestsNotifier, List<ServerPairRequest>>(
  (ref) => PendingPairRequestsNotifier(),
);

/// Token-free server-side connections initiated by other FastDrop devices.
class IncomingPeerConnectionsNotifier
    extends StateNotifier<Map<String, AuthenticatedPeer>> {
  IncomingPeerConnectionsNotifier() : super(const {});

  void connected(AuthenticatedPeer peer) {
    final next = Map<String, AuthenticatedPeer>.of(state)
      ..removeWhere((_, existing) => existing.deviceId == peer.deviceId)
      ..[peer.sessionId] = peer;
    state = next;
  }

  void disconnected(String sessionId) {
    if (!state.containsKey(sessionId)) return;
    state = Map<String, AuthenticatedPeer>.of(state)..remove(sessionId);
  }

  void clear() => state = const {};
}

final incomingPeerConnectionsProvider = StateNotifierProvider<
    IncomingPeerConnectionsNotifier, Map<String, AuthenticatedPeer>>(
  (ref) => IncomingPeerConnectionsNotifier(),
);
