// Thin HTTP client. All endpoints are same-origin via //go:embed web/dist
// in production; Vite proxies /api in dev.
import type {
  CreateTransferBody,
  CreateTransferResult,
  PairAccepted,
  PairRequestResponse,
  QRPayload,
  TransferRow,
} from './types'

const SESSION_KEY = 'fastdrop_session'

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

function authHeaders(): HeadersInit {
  if (!cachedSession) return {}
  return {
    Authorization: `Bearer ${cachedSession.accessToken}`,
    'X-Session-Id': cachedSession.sessionId,
  }
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

export async function pollPairStatus(requestId: string): Promise<PairRequestResponse> {
  return asJson(await fetch(`/api/v1/pair/requests/${requestId}`))
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
  deviceName: string
  platform: string
  status: string
  createdAt: number
}

export async function listPairRequests(): Promise<{ requests: PendingPairRequest[] }> {
  return asJson(await fetch('/api/v1/pair/requests'))
}

export async function listTransfers(): Promise<TransferRow[]> {
  const data = await asJson<{ transfers: TransferRow[] }>(await fetch('/api/v1/transfers', { headers: authHeaders() }))
  return data.transfers || []
}

export async function getTransfer(transferId: string): Promise<TransferRow> {
  return asJson<TransferRow>(await fetch(`/api/v1/transfers/${transferId}`, { headers: authHeaders() }))
}

export async function createTransfer(body: CreateTransferBody, signal?: AbortSignal): Promise<CreateTransferResult> {
  return asJson(await fetch('/api/v1/transfers', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...authHeaders() },
    body: JSON.stringify(body),
    signal,
  }))
}

export async function uploadChunk(url: string, data: ArrayBuffer, signal?: AbortSignal): Promise<void> {
  const resp = await fetch(url, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/octet-stream', ...authHeaders() },
    body: data,
    signal,
  })
  if (!resp.ok) throw new Error(`chunk upload failed: ${resp.status}`)
}

export async function completeFile(url: string, size: number, sha256: string, signal?: AbortSignal): Promise<{ sha256: string; savedPath: string }> {
  return asJson(await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...authHeaders() },
    body: JSON.stringify({ size, sha256 }),
    signal,
  }))
}

export async function cancelTransfer(transferId: string): Promise<void> {
  await fetch(`/api/v1/transfers/${transferId}/cancel`, { method: 'POST', headers: authHeaders() })
}

// ========== Settings ==========

export interface Settings {
  downloadDirectory: string
  conflictPolicy: string
  deviceName: string
}

export async function getSettings(): Promise<Settings> {
  return asJson(await fetch('/api/v1/settings'))
}

export async function updateSettings(body: {
  downloadDirectory?: string
  conflictPolicy?: string
}): Promise<Settings> {
  return asJson(await fetch('/api/v1/settings', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  }))
}

/// Download a file's content as a Blob (full GET, no Range).
export async function downloadFileBlob(transferId: string, fileId: string, signal?: AbortSignal): Promise<Blob> {
  const resp = await fetch(`/api/v1/transfers/${transferId}/files/${fileId}/content`, {
    headers: authHeaders(),
    signal,
  })
  if (!resp.ok) throw new Error(`download failed: ${resp.status}`)
  return resp.blob()
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
