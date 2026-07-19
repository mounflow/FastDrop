// Shared types matching the Go server's JSON contracts (spec §5–§22).

export interface QRPayload {
  version: number
  protocol: 'fastdrop'
  host: string
  port: number
  pairId: string
  token: string
  expiresAt: number
  serverName: string
}

export interface PairRequestResponse {
  requestId: string
  status: 'waiting_confirmation' | 'accepted' | 'rejected' | 'expired'
  expiresIn: number
}

export interface PairAccepted {
  status: 'accepted'
  session: {
    sessionId: string
    accessToken: string
    expiresIn: number
    websocketUrl: string
  }
  server: {
    deviceId: string
    deviceName: string
    platform: string
  }
}

export interface DeviceInfo {
  deviceId: string
  deviceName: string
  platform: string
  appVersion?: string
}

export interface CreateTransferBody {
  offerId: string
  direction: 'client_to_server' | 'server_to_client'
  files: Array<{
    clientFileId: string
    name: string
    size: number
    mimeType: string
    sha256?: string
  }>
}

export interface TransferFileResult {
  fileId: string
  clientFileId: string
  name: string
  chunkSize: number
  totalChunks: number
  uploadUrlTemplate: string
}

export interface CreateTransferResult {
  transferId: string
  files: TransferFileResult[]
}

export interface ApiError {
  error: {
    code: string
    message: string
    requestId: string
    details: Record<string, unknown>
  }
}

export interface TransferRow {
  id: string
  sessionId: string
  peerDeviceId: string
  direction: string
  status: string
  totalFiles: number
  totalBytes: number
  transferredBytes: number
  createdAt: number
  completedAt?: number
  errorCode?: string
  errorMessage?: string
}
