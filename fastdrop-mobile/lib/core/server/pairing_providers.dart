import 'package:fastdrop_mobile/core/server/pairing_handler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Riverpod state for incoming pair requests that need user confirmation.
///
/// The embedded server's [PairingHandler] pushes new requests here via
/// [addRequest]; the UI layer watches this provider and shows a
/// confirmation dialog.
class PendingPairRequestsNotifier extends StateNotifier<List<ServerPairRequest>> {
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
    state = state
        .where((r) => r.status == 'waiting_confirmation')
        .toList();
  }

  void clear() => state = [];
}

/// Provider for pending pair requests awaiting user confirmation.
final pendingPairRequestsProvider =
    StateNotifierProvider<PendingPairRequestsNotifier, List<ServerPairRequest>>(
  (ref) => PendingPairRequestsNotifier(),
);
