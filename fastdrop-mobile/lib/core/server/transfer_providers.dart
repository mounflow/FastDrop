import 'package:fastdrop_mobile/core/server/transfer_receiver.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Riverpod state for incoming transfers that need user confirmation.
class IncomingTransfersNotifier extends StateNotifier<List<ServerTransfer>> {
  IncomingTransfersNotifier() : super([]);

  void addTransfer(ServerTransfer transfer) {
    state = [...state, transfer];
  }

  void removeTransfer(String transferId) {
    state = state.where((t) => t.transferId != transferId).toList();
  }

  void updateStatus(String transferId, String status) {
    for (final t in state) {
      if (t.transferId == transferId) {
        t.status = status;
      }
    }
    // Remove resolved transfers from the pending list.
    state = state
        .where((t) => t.status == 'waiting_accept')
        .toList();
  }

  void clear() => state = [];
}

/// Provider for incoming transfers awaiting user confirmation.
final incomingTransfersProvider =
    StateNotifierProvider<IncomingTransfersNotifier, List<ServerTransfer>>(
  (ref) => IncomingTransfersNotifier(),
);

/// Riverpod state for active (in-progress) transfers on the server side.
class ActiveTransfersNotifier extends StateNotifier<List<ServerTransfer>> {
  ActiveTransfersNotifier() : super([]);

  void addTransfer(ServerTransfer transfer) {
    state = [...state, transfer];
  }

  void removeTransfer(String transferId) {
    state = state.where((t) => t.transferId != transferId).toList();
  }

  /// Refresh the list from the transfer receiver.
  void syncFrom(TransferReceiver receiver) {
    state = receiver.activeTransfers;
  }

  void clear() => state = [];
}

/// Provider for currently active server-side transfers (with progress).
final activeServerTransfersProvider =
    StateNotifierProvider<ActiveTransfersNotifier, List<ServerTransfer>>(
  (ref) => ActiveTransfersNotifier(),
);
