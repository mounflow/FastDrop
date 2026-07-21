/// Transfer-related models matching the Go backend's REST contracts (§20).
///
/// Covers creating transfers, per-file metadata, progress events, and
/// transfer history rows from `GET /api/v1/transfers`.

/// Request body for `POST /api/v1/transfers`.
class CreateTransferBody {
  const CreateTransferBody({
    required this.offerId,
    required this.direction,
    required this.files,
  });

  /// Correlation ID tying this transfer to an offer (client-generated for
  /// client-to-server uploads).
  final String offerId;

  /// Direction: `"client_to_server"` (phone -> PC) or `"server_to_client"` (PC -> phone).
  final String direction;

  final List<TransferFileInput> files;

  Map<String, dynamic> toJson() {
    return {
      'offerId': offerId,
      'direction': direction,
      'files': files.map((f) => f.toJson()).toList(),
    };
  }
}

/// Per-file metadata in a [CreateTransferBody] request.
class TransferFileInput {
  const TransferFileInput({
    required this.clientFileId,
    required this.name,
    required this.size,
    this.sha256,
    this.mimeType,
  });

  /// Client-generated unique ID for this file within the batch.
  final String clientFileId;

  final String name;
  final int size;
  final String? sha256;
  final String? mimeType;

  Map<String, dynamic> toJson() {
    return {
      'clientFileId': clientFileId,
      'name': name,
      'size': size,
      if (sha256 != null) 'sha256': sha256,
      if (mimeType != null) 'mimeType': mimeType,
    };
  }
}

/// The server's response when a transfer is created.
///
/// Go backend returns: `{transferId, files: [{fileId, clientFileId, name, chunkSize, totalChunks, uploadUrlTemplate}]}`
class CreateTransferResult {
  const CreateTransferResult({
    required this.transferId,
    required this.files,
  });

  final String transferId;
  final List<TransferFileResult> files;

  factory CreateTransferResult.fromJson(Map<String, dynamic> json) {
    return CreateTransferResult(
      transferId: json['transferId'] as String,
      files: (json['files'] as List<dynamic>)
          .map((f) =>
              TransferFileResult.fromJson(f as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'transferId': transferId,
      'files': files.map((f) => f.toJson()).toList(),
    };
  }
}

/// Per-file result returned by the server when a transfer is created.
///
/// Go backend returns: `{fileId, clientFileId, name, chunkSize, totalChunks, uploadUrlTemplate}`
class TransferFileResult {
  const TransferFileResult({
    required this.fileId,
    required this.name,
    required this.chunkSize,
    required this.totalChunks,
    this.clientFileId,
  });

  final String fileId;
  final String name;
  final int chunkSize;
  final int totalChunks;
  final String? clientFileId;

  factory TransferFileResult.fromJson(Map<String, dynamic> json) {
    return TransferFileResult(
      fileId: json['fileId'] as String,
      name: json['name'] as String,
      chunkSize: json['chunkSize'] as int,
      totalChunks: json['totalChunks'] as int,
      clientFileId: json['clientFileId'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'fileId': fileId,
      'name': name,
      'chunkSize': chunkSize,
      'totalChunks': totalChunks,
      if (clientFileId != null) 'clientFileId': clientFileId,
    };
  }
}

/// WebSocket progress message pushed from the server.
///
/// Go backend sends: `{transferId, fileId, transferredBytes, totalBytes, speedBps}`
class TransferProgress {
  const TransferProgress({
    required this.transferId,
    required this.fileId,
    required this.bytesTransferred,
    required this.totalBytes,
    this.fileName,
    this.status,
    this.speed,
  });

  final String transferId;
  final String fileId;
  final int bytesTransferred;
  final int totalBytes;
  final String? fileName;
  final String? status;
  final int? speed;

  factory TransferProgress.fromJson(Map<String, dynamic> json) {
    return TransferProgress(
      transferId: json['transferId'] as String,
      fileId: json['fileId'] as String,
      bytesTransferred: (json['transferredBytes'] ?? json['bytesTransferred'] ?? 0) as int,
      totalBytes: json['totalBytes'] as int,
      fileName: json['fileName'] as String?,
      status: json['status'] as String?,
      speed: (json['speedBps'] ?? json['speed']) as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'transferId': transferId,
      'fileId': fileId,
      'transferredBytes': bytesTransferred,
      'totalBytes': totalBytes,
      if (fileName != null) 'fileName': fileName,
      if (status != null) 'status': status,
      if (speed != null) 'speedBps': speed,
    };
  }

  double get progress =>
      totalBytes > 0 ? bytesTransferred / totalBytes : 0.0;
}

/// File completion confirmation: `POST .../complete` response.
///
/// Go backend returns: `{fileId, sha256, savedPath}`
class ChunkCompleteResult {
  const ChunkCompleteResult({
    required this.sha256,
    this.fileId,
    this.savedPath,
  });

  final String sha256;
  final String? fileId;
  final String? savedPath;

  factory ChunkCompleteResult.fromJson(Map<String, dynamic> json) {
    return ChunkCompleteResult(
      sha256: json['sha256'] as String,
      fileId: json['fileId'] as String?,
      savedPath: json['savedPath'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'sha256': sha256,
      if (fileId != null) 'fileId': fileId,
      if (savedPath != null) 'savedPath': savedPath,
    };
  }
}

/// Row returned by `GET /api/v1/transfers` listing past and active transfers.
class TransferRow {
  const TransferRow({
    required this.id,
    required this.sessionId,
    required this.peerDeviceId,
    required this.direction,
    required this.status,
    required this.totalFiles,
    required this.totalBytes,
    required this.transferredBytes,
    required this.createdAt,
    this.completedAt,
    this.errorCode,
    this.errorMessage,
  });

  final String id;
  final String sessionId;
  final String peerDeviceId;
  final String direction;
  final String status;
  final int totalFiles;
  final int totalBytes;
  final int transferredBytes;
  final int createdAt;
  final int? completedAt;
  final String? errorCode;
  final String? errorMessage;

  factory TransferRow.fromJson(Map<String, dynamic> json) {
    return TransferRow(
      id: json['id'] as String,
      sessionId: json['sessionId'] as String,
      peerDeviceId: json['peerDeviceId'] as String,
      direction: json['direction'] as String,
      status: json['status'] as String,
      totalFiles: json['totalFiles'] as int,
      totalBytes: json['totalBytes'] as int,
      transferredBytes: json['transferredBytes'] as int,
      createdAt: json['createdAt'] as int,
      completedAt: json['completedAt'] as int?,
      errorCode: json['errorCode'] as String?,
      errorMessage: json['errorMessage'] as String?,
    );
  }

  double get progress =>
      totalBytes > 0 ? transferredBytes / totalBytes : 0.0;
}
