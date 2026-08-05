import { computed, reactive, ref, type ComputedRef, type Ref } from 'vue'

import {
  announceTransfer,
  completeFile,
  createTransfer,
  downloadFileBlob,
  listTransfers,
  triggerBrowserDownload,
  uploadChunk,
  type ApiTarget,
} from '../api'
import { useWebSocket, type WSStatus } from './useWebSocket'
import type { CreateTransferResult, TransferRow } from '../types'

const PEERS_KEY = 'fastdrop_peer_sessions_v1'
const CHUNK_SIZE = 4 * 1024 * 1024

export interface PeerSession extends ApiTarget {
  id: string
  name: string
  platform: string
  baseUrl: string
  websocketUrl?: string
  role: 'local-session' | 'remote-server'
}

export interface PeerView extends PeerSession {
  status: WSStatus
}

export interface PeerTransferProgress {
  peerId: string
  peerName: string
  transferId: string
  fileId: string
  fileName: string
  transferredBytes: number
  totalBytes: number
  status: string
  error?: string
}

interface WSEnvelope {
  type?: string
  payload?: Record<string, unknown>
}

interface IncomingFile {
  fileId: string
  name: string
  size: number
  mimeType?: string
  sha256?: string
}

export interface PeerIncomingOffer {
  peerId: string
  transferId: string
  offerId: string
  deviceName: string
  files: IncomingFile[]
}

export interface PeerPoolHandlers {
  onMessage?: (peerId: string, message: unknown) => void
  onProgress?: (progress: PeerTransferProgress) => void
  onPeerChanged?: () => void
  onAuthFailed?: (peerId: string) => void
}

class AsyncLimiter {
  private active = 0
  private readonly waiters: Array<() => void> = []

  constructor(private readonly maximum: number) {}

  async run<T>(action: () => Promise<T>): Promise<T> {
    if (this.active < this.maximum) {
      this.active++
    } else {
      await new Promise<void>((resolve) => this.waiters.push(resolve))
    }
    try {
      return await action()
    } finally {
      const next = this.waiters.shift()
      if (next) next()
      else this.active--
    }
  }
}

interface Runtime {
  session: PeerSession
  ws: ReturnType<typeof useWebSocket>
}

export interface PeerPool {
  peers: Ref<PeerView[]>
  selectedIds: Ref<string[]>
  connectedPeers: ComputedRef<PeerView[]>
  addPeer: (session: PeerSession) => void
  removePeer: (peerId: string) => void
  restore: () => void
  close: () => void
  sendFiles: (files: File[], peerIds?: string[]) => Promise<void>
  send: (peerId: string, message: unknown) => void
  acceptOffer: (offer: PeerIncomingOffer) => Promise<void>
  rejectOffer: (offer: PeerIncomingOffer) => void
  loadHistory: () => Promise<Array<TransferRow & { peerId: string; peerName: string }>>
}

export function usePeerPool(handlers: PeerPoolHandlers = {}): PeerPool {
  const peers = ref<PeerView[]>([])
  const selectedIds = ref<string[]>([])
  const runtimes = new Map<string, Runtime>()
  const httpLimiter = new AsyncLimiter(6)
  const readiness = new Map<string, {
    resolve: () => void
    reject: (error: Error) => void
    timer: ReturnType<typeof setTimeout>
  }>()
  const resolvedReadiness = new Map<string, boolean>()

  const connectedPeers = computed(() =>
    peers.value.filter((peer) => peer.status === 'connected'),
  )

  function persist() {
    const sessions = peers.value.map(({ status: _status, ...session }) => session)
    sessionStorage.setItem(PEERS_KEY, JSON.stringify(sessions))
  }

  function updateStatus(peerId: string, status: WSStatus) {
    const peer = peers.value.find((item) => item.id === peerId)
    if (peer) peer.status = status
    handlers.onPeerChanged?.()
  }

  function wsUrl(session: PeerSession): string {
    if (session.websocketUrl) {
      const parsed = new URL(session.websocketUrl, session.baseUrl)
      // Some servers return a URL containing their configured host. The
      // explicitly paired base URL is the one proven reachable by this PC.
      const base = new URL(session.baseUrl)
      parsed.protocol = base.protocol === 'https:' ? 'wss:' : 'ws:'
      parsed.host = base.host
      return parsed.toString()
    }
    const base = new URL(session.baseUrl)
    base.protocol = base.protocol === 'https:' ? 'wss:' : 'ws:'
    base.pathname = '/ws/v1'
    base.search = ''
    return base.toString()
  }

  function addPeer(session: PeerSession) {
    removePeer(session.id, false)
    const view = reactive<PeerView>({ ...session, status: 'connecting' })
    peers.value.push(view)
    if (!selectedIds.value.includes(session.id)) {
      selectedIds.value.push(session.id)
    }

    const ws = useWebSocket({
      url: wsUrl(session),
      sessionId: session.sessionId,
      accessToken: session.accessToken,
      handlers: {
        onOpen: () => updateStatus(session.id, 'connected'),
        onClose: () => updateStatus(session.id, 'reconnecting'),
        onError: () => updateStatus(session.id, 'reconnecting'),
        onAuthFailed: () => {
          updateStatus(session.id, 'disconnected')
          handlers.onAuthFailed?.(session.id)
        },
        onMessage: (message) => handleMessage(session.id, message),
      },
    })
    runtimes.set(session.id, { session, ws })
    persist()
    handlers.onPeerChanged?.()
  }

  function removePeer(peerId: string, shouldPersist = true) {
    runtimes.get(peerId)?.ws.close()
    runtimes.delete(peerId)
    peers.value = peers.value.filter((peer) => peer.id !== peerId)
    selectedIds.value = selectedIds.value.filter((id) => id !== peerId)
    for (const [key, waiter] of readiness) {
      if (key.startsWith(`${peerId}::`)) {
        clearTimeout(waiter.timer)
        waiter.reject(new Error('Device disconnected'))
        readiness.delete(key)
      }
    }
    for (const key of resolvedReadiness.keys()) {
      if (key.startsWith(`${peerId}::`)) resolvedReadiness.delete(key)
    }
    if (shouldPersist) persist()
    handlers.onPeerChanged?.()
  }

  function restore() {
    try {
      const raw = sessionStorage.getItem(PEERS_KEY)
      if (!raw) return
      const sessions = JSON.parse(raw) as PeerSession[]
      for (const session of sessions) addPeer(session)
    } catch {
      sessionStorage.removeItem(PEERS_KEY)
    }
  }

  function close() {
    for (const runtime of runtimes.values()) runtime.ws.close()
    runtimes.clear()
    for (const waiter of readiness.values()) {
      clearTimeout(waiter.timer)
      waiter.reject(new Error('Peer pool closed'))
    }
    readiness.clear()
    resolvedReadiness.clear()
  }

  function send(peerId: string, message: unknown) {
    runtimes.get(peerId)?.ws.send(message)
  }

  function handleMessage(peerId: string, raw: unknown) {
    const message = raw as WSEnvelope
    const payload = message.payload ?? {}
    const runtime = runtimes.get(peerId)
    if (runtime?.session.role === 'local-session') {
      if (message.type === 'device.info') updateStatus(peerId, 'connected')
      if (message.type === 'device.disconnect') updateStatus(peerId, 'disconnected')
    }
    const transferId = (payload.transferId ?? payload.offerId ?? '') as string
    const accepted = message.type === 'transfer.accepted'
      || message.type === 'file.offer.accept'
    const rejected = message.type === 'transfer.rejected'
      || message.type === 'file.offer.reject'
    if (accepted || rejected) {
      const key = `${peerId}::${transferId}`
      const waiter = readiness.get(key)
      if (waiter) {
        clearTimeout(waiter.timer)
        readiness.delete(key)
        if (accepted) waiter.resolve()
        else waiter.reject(new Error('Recipient rejected the transfer'))
      } else {
        resolvedReadiness.set(key, accepted)
      }
    }
    handlers.onMessage?.(peerId, raw)
  }

  function waitForAcceptance(peerId: string, transferId: string): Promise<void> {
    const key = `${peerId}::${transferId}`
    const resolved = resolvedReadiness.get(key)
    if (resolved !== undefined) {
      resolvedReadiness.delete(key)
      return resolved
        ? Promise.resolve()
        : Promise.reject(new Error('Recipient rejected the transfer'))
    }
    return new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        readiness.delete(key)
        reject(new Error('Timed out waiting for recipient acceptance'))
      }, 120_000)
      readiness.set(key, { resolve, reject, timer })
    })
  }

  async function sendFiles(files: File[], peerIds = selectedIds.value) {
    const onlineIds = new Set(
      peers.value
        .filter((peer) => peer.status === 'connected')
        .map((peer) => peer.id),
    )
    const targets = peerIds
      .filter((id) => onlineIds.has(id))
      .map((id) => runtimes.get(id))
      .filter((runtime): runtime is Runtime => runtime !== undefined)
    if (targets.length === 0) throw new Error('Select at least one connected device')

    const jobs = targets.flatMap((runtime) =>
      files.map((file) => () => sendFile(runtime, file)),
    )
    await runJobs(jobs, 2)
  }

  async function sendFile(runtime: Runtime, file: File) {
    const { session } = runtime
    const sha256 = await sha256File(file)
    const offerId = crypto.randomUUID()
    const directUpload = session.role === 'remote-server'
    const result = await httpLimiter.run(() => createTransfer({
      offerId,
      direction: directUpload ? 'client_to_server' : 'server_to_client',
      files: [{
        clientFileId: crypto.randomUUID(),
        name: file.name,
        size: file.size,
        mimeType: file.type || 'application/octet-stream',
        sha256,
      }],
    }, undefined, session))
    const remoteFile = result.files[0]

    emitProgress(session, result, remoteFile.fileId, file, 0,
      directUpload && isConfirmationPlatform(session.platform)
        ? 'waiting_accept'
        : 'preparing')

    if (directUpload && isConfirmationPlatform(session.platform)) {
      await waitForAcceptance(session.id, result.transferId)
    }

    await uploadFileChunks(session, result, remoteFile.fileId, file)

    if (directUpload) {
      await httpLimiter.run(() => completeFile(
        `/api/v1/transfers/${result.transferId}/files/${remoteFile.fileId}/complete`,
        file.size,
        sha256,
        undefined,
        session,
      ))
      emitProgress(session, result, remoteFile.fileId, file, file.size, 'completed')
      return
    }

    await httpLimiter.run(() => announceTransfer(result.transferId, session))
    emitProgress(session, result, remoteFile.fileId, file, file.size, 'waiting_accept')
  }

  async function uploadFileChunks(
    session: PeerSession,
    result: CreateTransferResult,
    fileId: string,
    file: File,
  ) {
    const totalChunks = Math.ceil(file.size / CHUNK_SIZE)
    let transferred = 0
    const jobs = Array.from({ length: totalChunks }, (_, index) => async () => {
      const start = index * CHUNK_SIZE
      const end = Math.min(start + CHUNK_SIZE, file.size)
      const data = await file.slice(start, end).arrayBuffer()
      await httpLimiter.run(() => uploadChunk(
        `/api/v1/transfers/${result.transferId}/files/${fileId}/chunks/${index}`,
        data,
        undefined,
        session,
      ))
      transferred += data.byteLength
      emitProgress(session, result, fileId, file, transferred, 'transferring')
    })
    await runJobs(jobs, 3)
  }

  function emitProgress(
    session: PeerSession,
    result: CreateTransferResult,
    fileId: string,
    file: File,
    transferredBytes: number,
    status: string,
    error?: string,
  ) {
    handlers.onProgress?.({
      peerId: session.id,
      peerName: session.name,
      transferId: result.transferId,
      fileId,
      fileName: file.name,
      transferredBytes,
      totalBytes: file.size,
      status,
      error,
    })
  }

  async function acceptOffer(offer: PeerIncomingOffer) {
    const runtime = runtimes.get(offer.peerId)
    if (!runtime) throw new Error('Peer is no longer connected')
    runtime.ws.send({
      version: 1,
      type: 'file.offer.accept',
      messageId: crypto.randomUUID(),
      timestamp: Date.now(),
      payload: { offerId: offer.offerId },
    })
    for (const file of offer.files) {
      const blob = await httpLimiter.run(() => downloadFileBlob(
        offer.transferId,
        file.fileId,
        undefined,
        runtime.session,
      ))
      triggerBrowserDownload(blob, file.name)
    }
  }

  function rejectOffer(offer: PeerIncomingOffer) {
    send(offer.peerId, {
      version: 1,
      type: 'file.offer.reject',
      messageId: crypto.randomUUID(),
      timestamp: Date.now(),
      payload: { offerId: offer.offerId, reason: 'user_rejected' },
    })
  }

  async function loadHistory() {
    const rows = await Promise.all(peers.value.map(async (peer) => {
      try {
        const history = await listTransfers(peer)
        return history.map((row) => ({ ...row, peerId: peer.id, peerName: peer.name }))
      } catch {
        return []
      }
    }))
    return rows.flat().sort((a, b) => b.createdAt - a.createdAt)
  }

  return {
    peers,
    selectedIds,
    connectedPeers,
    addPeer,
    removePeer,
    restore,
    close,
    sendFiles,
    send,
    acceptOffer,
    rejectOffer,
    loadHistory,
  }
}

function isConfirmationPlatform(platform: string): boolean {
  return ['android', 'ios', 'macos'].includes(platform.toLowerCase())
}

async function sha256File(file: File): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', await file.arrayBuffer())
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('')
}

async function runJobs(
  jobs: Array<() => Promise<void>>,
  concurrency: number,
): Promise<void> {
  let next = 0
  const workers = Array.from(
    { length: Math.min(concurrency, jobs.length) },
    async () => {
      while (next < jobs.length) {
        const job = jobs[next++]
        await job()
      }
    },
  )
  await Promise.all(workers)
}
