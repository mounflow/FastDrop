// Thin HTTP client. All endpoints are same-origin via //go:embed web/dist
// in production; Vite proxies /api in dev.
import type {
  CreateTransferBody,
  CreateTransferResult,
  DeviceInfo,
  PairAccepted,
  PairRequestResponse,
  QRPayload,
  TransferRow,
} from './types'

const SESSION_KEY = 'fastdrop_session'

export interface ApiTarget {
  baseUrl?: string
  sessionId: string
  accessToken: string
}

let cachedSession: { sessionId: string; accessToken: string } | null = null

export function setSession(s: { sessionId: string; accessToken: string } | null) {
  cachedSession = s
  if (s) {
    sessionStorage.setItem(SESSION_KEY, JSON.stringify(s))
  } else {
    sessionStorage.removeItem(SESSION_KEY)
  }
}

/// Restore session from sessionStorage (survives page refresh, cleared on tab close).
export function restoreSession(): { sessionId: string; accessToken: string } | null {
  try {
    const raw = sessionStorage.getItem(SESSION_KEY)
    if (!raw) return null
    const s = JSON.parse(raw)
    if (s && s.sessionId && s.accessToken) {
      cachedSession = s
      return s
    }
  } catch { /* ignore */ }
  return null
}

function authHeaders(target?: ApiTarget): HeadersInit {
  const session = target ?? cachedSession
  if (!session) return {}
  return {
    Authorization: `Bearer ${session.accessToken}`,
    'X-Session-Id': session.sessionId,
  }
}

function targetUrl(path: string, target?: { baseUrl?: string }): string {
  if (!target?.baseUrl) return path
  return `${target.baseUrl.replace(/\/$/, '')}${path}`
}

async function asJson<T>(resp: Response): Promise<T> {
  if (!resp.ok) {
    const err = await resp.json().catch(() => ({ error: { code: 'INTERNAL_ERROR', message: resp.statusText } }))
    throw new Error(err.error?.code || 'INTERNAL_ERROR')
  }
  return resp.json() as Promise<T>
}

export async function fetchQR(): Promise<QRPayload> {
  return asJson(await fetch('/api/v1/pair/qr'))
}

export async function refreshPairToken(pairId: string): Promise<QRPayload> {
  return asJson(await fetch('/api/v1/pair/token/refresh', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...authHeaders() },
    body: JSON.stringify({ pairId }),
  }))
}

export async function pollPairStatus(requestId: string, baseUrl?: string): Promise<PairRequestResponse | PairAccepted> {
  return asJson(await fetch(`${baseUrl?.replace(/\/$/, '') ?? ''}/api/v1/pair/requests/${requestId}`))
}

export async function acceptPair(requestId: string): Promise<PairAccepted> {
  return asJson<PairAccepted>(await fetch(`/api/v1/pair/requests/${requestId}/accept`, {
    method: 'POST',
  }))
}

export async function rejectPair(requestId: string): Promise<void> {
  await fetch(`/api/v1/pair/requests/${requestId}/reject`, {
    method: 'POST',
    ...{ headers: authHeaders() } as RequestInit,
  })
}

export interface PendingPairRequest {
  requestId: string
  deviceId: string
  deviceName: string
  platform: string
  status: string
  createdAt: number
}

export async function listPairRequests(): Promise<{ requests: PendingPairRequest[] }> {
  const data = await asJson<{ requests: Array<PendingPairRequest & { device?: DeviceInfo }> }>(
    await fetch('/api/v1/pair/requests'),
  )
  return {
    requests: (data.requests || []).map((request) => ({
      requestId: request.requestId,
      deviceId: request.deviceId || request.device?.deviceId || request.requestId,
      deviceName: request.deviceName || request.device?.deviceName || 'Unknown Device',
      platform: request.platform || request.device?.platform || 'unknown',
      status: request.status,
      createdAt: request.createdAt,
    })),
  }
}

export async function listTransfers(target?: ApiTarget): Promise<TransferRow[]> {
  const data = await asJson<{ transfers: TransferRow[] }>(await fetch(targetUrl('/api/v1/transfers', target), { headers: authHeaders(target) }))
  return data.transfers || []
}

/// Revoke the current session (DELETE /api/v1/session). Server then
/// broadcasts session.revoked, which the Vue side already handles by
/// clearing state and falling back to the QR pairing page. Used by
/// the "重新配对" button when the user wants to pair a different
/// phone or recovery from a stale session.
export async function revokeSession(): Promise<void> {
  await fetch('/api/v1/session', {
    method: 'DELETE',
    headers: authHeaders(),
  })
}

export async function getTransfer(transferId: string, target?: ApiTarget): Promise<TransferRow> {
  return asJson<TransferRow>(await fetch(targetUrl(`/api/v1/transfers/${transferId}`, target), { headers: authHeaders(target) }))
}

export async function createTransfer(body: CreateTransferBody, signal?: AbortSignal, target?: ApiTarget): Promise<CreateTransferResult> {
  return asJson(await fetch(targetUrl('/api/v1/transfers', target), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...authHeaders(target) },
    body: JSON.stringify(body),
    signal,
  }))
}

export async function uploadChunk(url: string, data: ArrayBuffer, signal?: AbortSignal, target?: ApiTarget): Promise<void> {
  const resp = await fetch(url.startsWith('http') ? url : targetUrl(url, target), {
    method: 'PUT',
    headers: { 'Content-Type': 'application/octet-stream', ...authHeaders(target) },
    body: data,
    signal,
  })
  if (!resp.ok) throw new Error(`chunk upload failed: ${resp.status}`)
}

export async function completeFile(url: string, size: number, sha256: string, signal?: AbortSignal, target?: ApiTarget): Promise<{ sha256: string; savedPath: string }> {
  return asJson(await fetch(url.startsWith('http') ? url : targetUrl(url, target), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...authHeaders(target) },
    body: JSON.stringify({ size, sha256 }),
    signal,
  }))
}

export async function cancelTransfer(transferId: string, target?: ApiTarget): Promise<void> {
  await fetch(targetUrl(`/api/v1/transfers/${transferId}/cancel`, target), { method: 'POST', headers: authHeaders(target) })
}

export async function announceTransfer(transferId: string, target?: ApiTarget): Promise<void> {
  const response = await fetch(targetUrl(`/api/v1/transfers/${transferId}/offer`, target), {
    method: 'POST',
    headers: authHeaders(target),
  })
  if (!response.ok) throw new Error(`offer failed: ${response.status}`)
}

// ========== Settings ==========

export interface Settings {
  downloadDirectory: string
  conflictPolicy: string
  deviceName: string
  mdnsEnabled: boolean
  requirePairConfirmation: boolean
}

export async function getSettings(): Promise<Settings> {
  return asJson(await fetch('/api/v1/settings'))
}

export async function updateSettings(body: {
  downloadDirectory?: string
  conflictPolicy?: string
  mdnsEnabled?: boolean
  requirePairConfirmation?: boolean
}): Promise<Settings> {
  return asJson(await fetch('/api/v1/settings', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  }))
}

/// Download a file's content as a Blob (full GET, no Range).
export async function downloadFileBlob(transferId: string, fileId: string, signal?: AbortSignal, target?: ApiTarget): Promise<Blob> {
  const resp = await fetch(targetUrl(`/api/v1/transfers/${transferId}/files/${fileId}/content`, target), {
    headers: authHeaders(target),
    signal,
  })
  if (!resp.ok) throw new Error(`download failed: ${resp.status}`)
  return resp.blob()
}

export interface ServerInfo {
  deviceId: string
  name: string
  platform: string
  protocol: number
  port: number
}

export async function getServerInfo(baseUrl = ''): Promise<ServerInfo> {
  const root = baseUrl.replace(/\/$/, '')
  const response = await fetch(`${root}/api/v1/server/info`)
  if (response.ok) return asJson(response)
  const health = await asJson<{
    deviceId?: string
    deviceName?: string
    platform?: string
    protocol?: number
  }>(await fetch(`${root}/api/v1/health`))
  return {
    deviceId: health.deviceId || `${health.deviceName || 'peer'}@${root}`,
    name: health.deviceName || 'FastDrop Device',
    platform: health.platform || 'unknown',
    protocol: health.protocol || 1,
    port: Number(new URL(root || location.origin).port || 9527),
  }
}

export async function requestDiscoverPair(baseUrl: string, device: DeviceInfo): Promise<PairRequestResponse> {
  return asJson(await fetch(`${baseUrl.replace(/\/$/, '')}/api/v1/pair/discover`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ device }),
  }))
}

/// Trigger a browser file-save dialog for the given Blob.
export function triggerBrowserDownload(blob: Blob, fileName: string): void {
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = fileName
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  URL.revokeObjectURL(url)
}
