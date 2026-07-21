<script setup lang="ts">
import { onMounted, onUnmounted, ref } from 'vue'
import QRCode from 'qrcode'
import {
  acceptPair,
  createTransfer,
  downloadFileBlob,
  fetchQR,
  getTransfer,
  listPairRequests,
  listTransfers,
  rejectPair,
  setSession,
  triggerBrowserDownload,
  uploadChunk,
} from './api'
import { useWebSocket } from './composables/useWebSocket'
import type { CreateTransferResult, QRPayload, TransferRow } from './types'
import type { WSStatus } from './composables/useWebSocket'

// ========== Typed WS message ==========
interface WSEnvelope {
  version?: number
  type: string
  messageId?: string
  timestamp?: number
  payload?: Record<string, unknown>
}

// ========== QR code / server info ==========
const qrDataUrl = ref<string>('')
const qrPayload = ref<QRPayload | null>(null)
const countdown = ref<number>(0)
const serverName = ref<string>('FastDrop-PC')
const qrLoading = ref(false)
const qrError = ref<string | null>(null)

let qrTimer: ReturnType<typeof setInterval> | null = null
let countdownTimer: ReturnType<typeof setInterval> | null = null

async function refreshQR() {
  if (isPaired.value) return
  qrLoading.value = true
  qrError.value = null
  try {
    const payload = await fetchQR()
    qrPayload.value = payload
    serverName.value = payload.serverName
    countdown.value = Math.max(0, payload.expiresAt - Math.floor(Date.now() / 1000))
    qrDataUrl.value = await QRCode.toDataURL(JSON.stringify(payload), { width: 256 })
  } catch (e) {
    qrError.value = 'Failed to load QR code'
    console.error(e)
  } finally {
    qrLoading.value = false
  }
}

function tickCountdown() {
  if (countdown.value > 0) countdown.value--
  if (countdown.value === 0 && !isPaired.value) refreshQR()
}

// ========== Drag-and-drop + file picker upload ==========
const dragOver = ref(false)
const uploadStatus = ref<string>('')
const fileInput = ref<HTMLInputElement | null>(null)

async function handleDragOver(e: DragEvent) {
  e.preventDefault()
  dragOver.value = true
}

function handleDragLeave() {
  dragOver.value = false
}

async function handleDrop(e: DragEvent) {
  e.preventDefault()
  dragOver.value = false
  const files = Array.from(e.dataTransfer?.files || [])
  if (files.length === 0) return
  await sendFiles(files)
}

function openFilePicker() {
  fileInput.value?.click()
}

async function handleFilePickerChange(e: Event) {
  const input = e.target as HTMLInputElement
  const files = Array.from(input.files || [])
  input.value = '' // reset so the same file can be re-selected
  if (files.length === 0) return
  await sendFiles(files)
}

async function sendFiles(files: File[]) {
  if (!isPaired.value || !wsClient) {
    uploadStatus.value = 'Pair a phone first before sending files.'
    return
  }
  uploadStatus.value = `Preparing ${files.length} file(s)...`
  for (const f of files) {
    try {
      await stageAndOfferFile(f)
    } catch (e) {
      uploadStatus.value = `Failed: ${(e as Error).message}`
    }
  }
}

// stageAndOfferFile implements the spec §11 PC -> phone flow:
//   1. Create a server_to_client transfer (file will be staged on the PC).
//   2. Upload chunks to stage the bytes on the server's .part file.
//   3. Emit file.offer over WS so the phone can accept + Range-download.
//
// Note: we deliberately do NOT call /complete here — that path renames
// the .part file into the downloads dir, which we don't want for a file
// the phone is about to pull from the .part path.
async function stageAndOfferFile(file: File) {
  const offerId = crypto.randomUUID()
  const createBody = {
    offerId,
    direction: 'server_to_client' as const,
    files: [
      {
        clientFileId: file.name,
        name: file.name,
        size: file.size,
        mimeType: file.type || 'application/octet-stream',
      },
    ],
  }
  const res: CreateTransferResult = await createTransfer(createBody)
  const f = res.files[0]
  const chunkSize = f.chunkSize
  for (let i = 0; i < f.totalChunks; i++) {
    const start = i * chunkSize
    const end = Math.min(start + chunkSize, file.size)
    const buf = await file.slice(start, end).arrayBuffer()
    const url = `/api/v1/transfers/${res.transferId}/files/${f.fileId}/chunks/${i}`
    await uploadChunk(url, buf)
    uploadStatus.value = `${file.name}: staged ${i + 1}/${f.totalChunks} chunks`
  }
  // Announce the offer to the phone. The phone replies with file.offer.accept
  // and then Range-downloads via GET .../content.
  wsClient?.send({
    version: 1,
    type: 'file.offer',
    messageId: crypto.randomUUID(),
    timestamp: Date.now(),
    payload: {
      offerId,
      transferId: res.transferId,
      files: [
        {
          fileId: f.fileId,
          clientFileId: file.name,
          name: file.name,
          size: file.size,
          mimeType: file.type || 'application/octet-stream',
          modifiedAt: Math.floor(file.lastModified / 1000),
        },
      ],
    },
  })
  uploadStatus.value = `${file.name} offered to phone`
}

// ========== Pair request polling ==========
interface PendingDevice {
  requestId: string
  deviceName: string
  platform: string
}
const pendingRequests = ref<PendingDevice[]>([])
const showPairDialog = ref(false)
const isPaired = ref(false)

let pairPollTimer: ReturnType<typeof setInterval> | null = null

async function pollPairRequests() {
  if (isPaired.value) return
  try {
    const res = await listPairRequests()
    const waiting = (res.requests || []).filter(
      (r) => r.status === 'waiting_confirmation',
    )
    if (waiting.length > 0) {
      pendingRequests.value = waiting
      showPairDialog.value = true
    }
  } catch {
    // endpoint may not be available yet; silently retry
  }
}

async function handleAccept(requestId: string) {
  try {
    const res = await acceptPair(requestId)
    setSession({
      sessionId: res.session.sessionId,
      accessToken: res.session.accessToken,
    })
    showPairDialog.value = false
    pendingRequests.value = []
    isPaired.value = true
    if (res.session.websocketUrl) {
      connectWS(res.session.sessionId, res.session.accessToken, res.session.websocketUrl)
    }
  } catch (e) {
    console.error('Accept failed:', e)
  }
}

async function handleReject(requestId: string) {
  try {
    await rejectPair(requestId)
    showPairDialog.value = false
    pendingRequests.value = pendingRequests.value.filter((r) => r.requestId !== requestId)
  } catch (e) {
    console.error('Reject failed:', e)
  }
}

// ========== WebSocket ==========
const wsStatus = ref<WSStatus>('disconnected')
let wsClient: ReturnType<typeof useWebSocket> | null = null

interface IncomingOffer {
  transferId: string
  deviceName: string
  files: Array<{ fileId: string; name: string; size: number; mimeType: string }>
}
const incomingOffers = ref<IncomingOffer[]>([])

interface ActiveTransfer {
  transferId: string
  fileId: string
  filename: string
  totalBytes: number
  transferredBytes: number
  speedBps: number
  status: 'transferring' | 'paused' | 'verifying' | 'completed' | 'failed'
  error?: string
}
const activeTransfers = ref<ActiveTransfer[]>([])

function pauseTransfer(transferId: string) {
  const t = activeTransfers.value.find((t) => t.transferId === transferId)
  if (t) t.status = 'paused'
  wsClient?.send({
    version: 1,
    type: 'transfer.pause',
    messageId: crypto.randomUUID(),
    timestamp: Date.now(),
    payload: { transferId },
  })
}

function resumeTransfer(transferId: string) {
  const t = activeTransfers.value.find((t) => t.transferId === transferId)
  if (t) t.status = 'transferring'
  wsClient?.send({
    version: 1,
    type: 'transfer.resume',
    messageId: crypto.randomUUID(),
    timestamp: Date.now(),
    payload: { transferId },
  })
}

function retryTransfer(transferId: string) {
  // Remove from active list; user re-selects files to retry.
  activeTransfers.value = activeTransfers.value.filter(
    (t) => t.transferId !== transferId,
  )
}

function connectWS(sessionId: string, accessToken: string, wsUrl: string) {
  wsClient = useWebSocket({
    url: wsUrl,
    sessionId,
    accessToken,
    handlers: {
      onOpen: () => { wsStatus.value = 'connected' },
      onMessage: handleWSMessage,
      onClose: () => {
        if (wsStatus.value !== 'disconnected') {
          wsStatus.value = 'reconnecting'
        }
      },
      onError: () => {},
      onAuthFailed: () => {
        // Session revoked (e.g. server restarted) — reset to pairing.
        isPaired.value = false
        wsStatus.value = 'disconnected'
        activeTransfers.value = []
        incomingOffers.value = []
        wsClient = null
        refreshQR()
      },
    },
  })
  wsStatus.value = 'connecting'
}

function handleWSMessage(raw: unknown) {
  const msg = raw as WSEnvelope
  if (!msg?.type) return
  const p = (msg.payload ?? {}) as Record<string, unknown>

  switch (msg.type) {
    case 'file.offer': {
      incomingOffers.value.push({
        transferId: p.transferId as string,
        deviceName: (p.deviceName as string) || 'Phone',
        files: (p.files as IncomingOffer['files']) || [],
      })
      break
    }
    case 'transfer.started': {
      const t = activeTransfers.value.find(
        (t) => t.transferId === p.transferId,
      )
      if (t) t.status = 'transferring'
      break
    }
    case 'transfer.progress': {
      const existing = activeTransfers.value.find(
        (t) => t.transferId === p.transferId,
      )
      if (existing) {
        existing.transferredBytes = p.transferredBytes as number
        existing.speedBps = (p.speedBps as number) || 0
        existing.status = 'transferring'
      }
      break
    }
    case 'transfer.verifying': {
      const t = activeTransfers.value.find(
        (t) => t.transferId === p.transferId,
      )
      if (t) t.status = 'verifying'
      break
    }
    case 'transfer.paused': {
      const t = activeTransfers.value.find(
        (t) => t.transferId === p.transferId,
      )
      if (t) t.status = 'paused'
      break
    }
    case 'transfer.resume': {
      const t = activeTransfers.value.find(
        (t) => t.transferId === p.transferId,
      )
      if (t) t.status = 'transferring'
      break
    }
    case 'transfer.completed': {
      let completed = activeTransfers.value.filter(
        (t) => t.transferId === p.transferId,
      )
      // Race condition: transfer may complete before the user clicks
      // Accept, so it's still in incomingOffers. Auto-promote it.
      if (completed.length === 0) {
        const offerIdx = incomingOffers.value.findIndex(
          (o) => o.transferId === p.transferId,
        )
        if (offerIdx >= 0) {
          const offer = incomingOffers.value[offerIdx]
          incomingOffers.value.splice(offerIdx, 1)
          for (const f of offer.files) {
            activeTransfers.value.push({
              transferId: offer.transferId,
              fileId: f.fileId,
              filename: f.name,
              totalBytes: f.size,
              transferredBytes: f.size,
              speedBps: 0,
              status: 'completed',
            })
          }
          completed = activeTransfers.value.filter(
            (t) => t.transferId === p.transferId,
          )
        }
      }
      for (const t of completed) {
        t.status = 'completed'
        t.transferredBytes = t.totalBytes
      }
      loadHistory()
      break
    }
    case 'transfer.failed': {
      const t = activeTransfers.value.find(
        (t) => t.transferId === p.transferId,
      )
      if (t) {
        t.status = 'failed'
        // Go sends error as a plain string, not {message}.
        t.error = typeof p.error === 'string'
          ? p.error
          : (p.error as Record<string, string>)?.message || 'Transfer failed'
      }
      loadHistory()
      break
    }
    case 'transfer.cancelled': {
      const idx = activeTransfers.value.findIndex(
        (t) => t.transferId === p.transferId,
      )
      if (idx >= 0) activeTransfers.value.splice(idx, 1)
      loadHistory()
      break
    }
    case 'error': {
      // Server-side error notification.
      const code = (p.code as string) || 'UNKNOWN'
      const message = (p.message as string) || 'Server error'
      uploadStatus.value = `[${code}] ${message}`
      break
    }
    case 'device.disconnect': {
      // Phone disconnected — mark active transfers accordingly.
      for (const t of activeTransfers.value) {
        if (t.status === 'transferring' || t.status === 'paused') {
          t.status = 'failed'
          t.error = 'Device disconnected'
        }
      }
      break
    }
    case 'session.revoked': {
      // Session was revoked — reset all state.
      isPaired.value = false
      activeTransfers.value = []
      incomingOffers.value = []
      wsClient?.close()
      wsClient = null
      wsStatus.value = 'disconnected'
      refreshQR()
      break
    }
  }
}

async function acceptOffer(offer: IncomingOffer) {
  incomingOffers.value = incomingOffers.value.filter(
    (o) => o.transferId !== offer.transferId,
  )
  for (const f of offer.files) {
    activeTransfers.value.push({
      transferId: offer.transferId,
      fileId: f.fileId,
      filename: f.name,
      totalBytes: f.size,
      transferredBytes: 0,
      speedBps: 0,
      status: 'transferring',
    })
  }
  wsClient?.send({
    version: 1,
    type: 'file.offer.accept',
    messageId: crypto.randomUUID(),
    timestamp: Date.now(),
    payload: { offerId: offer.transferId },
  })
  // The transfer may have already completed before the user clicked
  // Accept (small files upload in <200 ms). Poll the server once to
  // sync the real status so the UI doesn't stick on "transferring".
  try {
    const row = await getTransfer(offer.transferId)
    if (row.status === 'completed' || row.status === 'verifying') {
      for (const t of activeTransfers.value.filter(
        (t) => t.transferId === offer.transferId,
      )) {
        t.status = 'completed'
        t.transferredBytes = t.totalBytes
      }
      loadHistory()
    }
  } catch (_) {
    // Best-effort; WS events will update the status eventually.
  }
}

function rejectOffer(offer: IncomingOffer) {
  incomingOffers.value = incomingOffers.value.filter(
    (o) => o.transferId !== offer.transferId,
  )
  wsClient?.send({
    version: 1,
    type: 'file.offer.reject',
    messageId: crypto.randomUUID(),
    timestamp: Date.now(),
    payload: { offerId: offer.transferId, reason: 'user_rejected' },
  })
}

function cancelTransfer(transferId: string) {
  activeTransfers.value = activeTransfers.value.filter(
    (t) => t.transferId !== transferId,
  )
  wsClient?.send({
    version: 1,
    type: 'transfer.cancel',
    messageId: crypto.randomUUID(),
    timestamp: Date.now(),
    payload: { transferId },
  })
}

// ========== Transfer history ==========
const transfers = ref<TransferRow[]>([])
const historyLoading = ref(false)

async function loadHistory() {
  historyLoading.value = true
  try {
    transfers.value = await listTransfers()
  } catch {
    transfers.value = []
  } finally {
    historyLoading.value = false
  }
}

// ========== Helpers ==========
function formatSize(bytes: number): string {
  if (bytes >= 1_000_000_000) return `${(bytes / 1_000_000_000).toFixed(1)} GB`
  if (bytes >= 1_000_000) return `${(bytes / 1_000_000).toFixed(1)} MB`
  if (bytes >= 1_000) return `${(bytes / 1_000).toFixed(0)} KB`
  return `${bytes} B`
}

function formatSpeed(bps: number): string {
  if (bps <= 0) return ''
  return `${formatSize(Math.round(bps))}/s`
}

function progressPercent(t: ActiveTransfer): number {
  if (t.totalBytes <= 0) return 0
  return Math.min(100, Math.round((t.transferredBytes / t.totalBytes) * 100))
}

// ========== Lifecycle ==========
function cleanup() {
  if (qrTimer) clearInterval(qrTimer)
  if (countdownTimer) clearInterval(countdownTimer)
  if (pairPollTimer) clearInterval(pairPollTimer)
  wsClient?.close()
}

onMounted(async () => {
  await refreshQR()
  qrTimer = setInterval(refreshQR, 50_000)
  countdownTimer = setInterval(tickCountdown, 1000)
  pairPollTimer = setInterval(pollPairRequests, 2000)
  await loadHistory()
})

onUnmounted(cleanup)
</script>

<template>
  <main class="app">
    <header>
      <h1>FastDrop</h1>
      <p class="server">{{ serverName }}</p>
      <div class="ws-indicator" :class="wsStatus" :title="`WebSocket: ${wsStatus}`">
        <span class="ws-dot"></span>
        <span class="ws-label">{{ wsStatus }}</span>
      </div>
    </header>

    <!-- Pair confirmation dialog -->
    <Teleport to="body">
      <div v-if="showPairDialog && pendingRequests.length" class="modal-overlay" @click.self="() => {}">
        <div class="modal-card" role="dialog" aria-label="Pairing Request">
          <div class="modal-header">
            <h2>Pairing Request</h2>
            <button class="modal-close" aria-label="Close" @click="showPairDialog = false">&times;</button>
          </div>
          <div
            v-for="req in pendingRequests"
            :key="req.requestId"
            class="pair-request-item"
          >
            <div class="pair-device-icon">&#x1F4F1;</div>
            <div class="pair-device-info">
              <strong>{{ req.deviceName || 'Unknown Device' }}</strong>
              <span class="pair-platform">{{ req.platform || 'unknown' }}</span>
            </div>
            <div class="pair-actions">
              <button class="btn btn-accept" @click="handleAccept(req.requestId)">Accept</button>
              <button class="btn btn-reject" @click="handleReject(req.requestId)">Reject</button>
            </div>
          </div>
        </div>
      </div>
    </Teleport>

    <!-- QR code -->
    <section v-if="!isPaired" class="qr">
      <div v-if="qrLoading && !qrDataUrl" class="qr-loading">Loading QR...</div>
      <div v-else-if="qrError" class="qr-error">
        <p>{{ qrError }}</p>
        <button class="btn btn-accept" @click="refreshQR">Retry</button>
      </div>
      <template v-else-if="qrPayload">
        <img :src="qrDataUrl" alt="QR Code" />
        <p v-if="countdown > 0">QR refreshes in {{ countdown }}s</p>
        <p class="address">{{ qrPayload.host }}:{{ qrPayload.port }}</p>
      </template>
    </section>

    <!-- Drop zone + file picker -->
    <section
      class="dropzone"
      :class="{ active: dragOver }"
      @dragover="handleDragOver"
      @dragleave="handleDragLeave"
      @drop="handleDrop"
      @click="openFilePicker"
      role="button"
      tabindex="0"
      aria-label="Drop files here or click to browse"
    >
      Drop files here or click to browse
      <input
        ref="fileInput"
        type="file"
        multiple
        style="display: none"
        @change="handleFilePickerChange"
      />
    </section>
    <p v-if="uploadStatus" class="status">{{ uploadStatus }}</p>

    <!-- Incoming file offers -->
    <section v-if="incomingOffers.length" class="offers">
      <h3>Incoming Files</h3>
      <div
        v-for="offer in incomingOffers"
        :key="offer.transferId"
        class="offer-card"
      >
        <div class="offer-header">
          <span class="offer-from">From: {{ offer.deviceName }}</span>
          <span class="offer-count">{{ offer.files.length }} file(s)</span>
        </div>
        <ul class="offer-files">
          <li v-for="f in offer.files" :key="f.fileId">
            {{ f.name }} ({{ formatSize(f.size) }})
          </li>
        </ul>
        <div class="offer-actions">
          <button class="btn btn-accept" @click="acceptOffer(offer)">Accept</button>
          <button class="btn btn-reject" @click="rejectOffer(offer)">Reject</button>
        </div>
      </div>
    </section>

    <!-- Active transfers -->
    <section v-if="activeTransfers.length" class="transfers">
      <h3>Active Transfers</h3>
      <div
        v-for="t in activeTransfers"
        :key="t.transferId"
        class="transfer-item"
      >
        <div class="transfer-info">
          <span class="transfer-name">{{ t.filename }}</span>
          <span class="transfer-status">{{ t.status }}</span>
        </div>
        <div class="progress-bar">
          <div
            class="progress-fill"
            :class="t.status"
            :style="{ width: progressPercent(t) + '%' }"
          ></div>
        </div>
        <div class="transfer-details">
          <span>{{ formatSize(t.transferredBytes) }} / {{ formatSize(t.totalBytes) }}</span>
          <span v-if="t.status === 'transferring' && t.speedBps > 0" class="transfer-speed">
            {{ formatSpeed(t.speedBps) }}
          </span>
          <span v-if="t.status === 'completed'" class="done-label">Done</span>
          <span v-if="t.status === 'failed'" class="error-label" :title="t.error">Failed</span>
          <span class="transfer-actions">
            <button
              v-if="t.status === 'transferring'"
              class="btn-cancel"
              @click="pauseTransfer(t.transferId)"
            >
              Pause
            </button>
            <button
              v-if="t.status === 'paused'"
              class="btn-cancel"
              @click="resumeTransfer(t.transferId)"
            >
              Resume
            </button>
            <button
              v-if="t.status === 'transferring' || t.status === 'paused'"
              class="btn-cancel"
              @click="cancelTransfer(t.transferId)"
            >
              Cancel
            </button>
            <button
              v-if="t.status === 'failed'"
              class="btn-cancel"
              @click="retryTransfer(t.transferId)"
            >
              Retry
            </button>
          </span>
        </div>
      </div>
    </section>

    <!-- History -->
    <section class="history">
      <h3>History <span v-if="historyLoading" class="history-loading">loading...</span></h3>
      <ul>
        <li v-for="t in transfers" :key="t.id" class="history-item">
          <span class="history-status" :class="t.status">{{ t.status }}</span>
          <span class="history-dir">{{ t.direction === 'client_to_server' ? '📥' : '📤' }}</span>
          <span class="history-size">{{ formatSize(t.transferredBytes) }} / {{ formatSize(t.totalBytes) }}</span>
          <span class="history-time">{{ t.createdAt ? new Date(t.createdAt * 1000).toLocaleTimeString() : '' }}</span>
          <span v-if="t.errorMessage" class="history-error" :title="t.errorMessage">⚠</span>
        </li>
        <li v-if="transfers.length === 0 && !historyLoading">No records</li>
      </ul>
    </section>
  </main>
</template>

<style scoped>
.app {
  max-width: 520px;
  margin: 0 auto;
  padding: 24px;
  font-family: system-ui, sans-serif;
  color: #222;
}

/* ---- header ---- */
h1 { margin: 0; font-size: 28px; }
.server { color: #666; margin: 4px 0 24px; }

/* ---- WS indicator ---- */
.ws-indicator {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 12px;
  color: #999;
}
.ws-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: #ccc;
}
.ws-indicator.connected .ws-dot { background: #22c55e; }
.ws-indicator.connecting .ws-dot { background: #eab308; animation: pulse 1s infinite; }
.ws-indicator.reconnecting .ws-dot { background: #f97316; animation: pulse 1.5s infinite; }
.ws-indicator.disconnected .ws-dot { background: #ef4444; }
.ws-label { text-transform: capitalize; }

@keyframes pulse {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.3; }
}

/* ---- Modal ---- */
.modal-overlay {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.45);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 1000;
}
.modal-card {
  background: #fff;
  border-radius: 16px;
  padding: 28px 32px;
  min-width: 340px;
  max-width: 440px;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.18);
}
.modal-card h2 {
  margin: 0 0 20px;
  font-size: 20px;
}
.pair-request-item {
  display: flex;
  align-items: center;
  gap: 14px;
  padding: 14px 0;
  border-top: 1px solid #eee;
}
.pair-device-icon {
  font-size: 28px;
  flex-shrink: 0;
}
.pair-device-info {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 2px;
}
.pair-platform {
  font-size: 13px;
  color: #888;
}
.pair-actions {
  display: flex;
  gap: 8px;
  flex-shrink: 0;
}

/* ---- Buttons ---- */
.btn {
  padding: 6px 16px;
  border: none;
  border-radius: 8px;
  font-size: 14px;
  cursor: pointer;
  font-weight: 500;
}
.btn-accept {
  background: #22c55e;
  color: #fff;
}
.btn-accept:hover { background: #16a34a; }
.btn-reject {
  background: #ef4444;
  color: #fff;
}
.btn-reject:hover { background: #dc2626; }
.btn-cancel {
  padding: 2px 10px;
  border: 1px solid #ddd;
  border-radius: 6px;
  background: #fff;
  font-size: 12px;
  cursor: pointer;
  color: #888;
}
.btn-cancel:hover { background: #f5f5f5; }

/* ---- QR ---- */
.qr { text-align: center; margin-bottom: 24px; }
.qr img { width: 256px; height: 256px; border-radius: 12px; border: 1px solid #ddd; }
.address { font-family: monospace; color: #555; }
.qr-loading { padding: 80px 0; color: #888; }
.qr-error { padding: 40px 0; color: #ef4444; }
.qr-error .btn { margin-top: 12px; }

/* ---- Drop zone ---- */
.dropzone {
  border: 2px dashed #aaa;
  border-radius: 12px;
  padding: 32px;
  text-align: center;
  color: #888;
  transition: all 0.2s;
  cursor: pointer;
}
.dropzone:hover {
  border-color: #4a90e2;
  color: #4a90e2;
}
.dropzone.active {
  border-color: #4a90e2;
  background: #eef5fc;
  color: #4a90e2;
}
.status { color: #4a90e2; margin-top: 8px; font-size: 14px; }

/* ---- Offers ---- */
.offers {
  margin-top: 28px;
}
.offers h3 {
  margin: 0 0 12px;
  font-size: 16px;
}
.offer-card {
  border: 1px solid #e5e7eb;
  border-radius: 12px;
  padding: 16px;
  margin-bottom: 12px;
}
.offer-header {
  display: flex;
  justify-content: space-between;
  margin-bottom: 8px;
  font-size: 14px;
}
.offer-from { font-weight: 600; }
.offer-count { color: #888; }
.offer-files {
  list-style: none;
  padding: 0;
  margin: 0 0 12px;
  font-size: 13px;
  color: #555;
}
.offer-files li {
  padding: 2px 0;
}
.offer-actions {
  display: flex;
  gap: 8px;
  justify-content: flex-end;
}

/* ---- Transfers ---- */
.transfers {
  margin-top: 28px;
}
.transfers h3 {
  margin: 0 0 12px;
  font-size: 16px;
}
.transfer-item {
  border: 1px solid #e5e7eb;
  border-radius: 12px;
  padding: 14px 16px;
  margin-bottom: 10px;
}
.transfer-info {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 8px;
}
.transfer-name {
  font-size: 14px;
  font-weight: 500;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.transfer-status {
  font-size: 12px;
  color: #888;
  text-transform: capitalize;
  flex-shrink: 0;
  margin-left: 12px;
}
.progress-bar {
  height: 6px;
  background: #eee;
  border-radius: 3px;
  overflow: hidden;
  margin-bottom: 6px;
}
.progress-fill {
  height: 100%;
  border-radius: 3px;
  background: #4a90e2;
  transition: width 0.3s ease;
}
.progress-fill.completed { background: #22c55e; }
.progress-fill.failed { background: #ef4444; }
.progress-fill.paused { background: #eab308; }
.progress-fill.verifying { background: #a855f7; }
.transfer-details {
  display: flex;
  justify-content: space-between;
  align-items: center;
  font-size: 12px;
  color: #888;
}
.transfer-speed {
  font-weight: 600;
  color: #4a90e2;
}
.done-label { color: #22c55e; font-weight: 600; }
.error-label { color: #ef4444; cursor: help; }
.transfer-actions { display: inline-flex; gap: 6px; }

/* ---- Modal close ---- */
.modal-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
}
.modal-header h2 { margin: 0; }
.modal-close {
  background: none;
  border: none;
  font-size: 24px;
  cursor: pointer;
  color: #999;
  line-height: 1;
  padding: 0 4px;
}
.modal-close:hover { color: #333; }

/* ---- History ---- */
.history { margin-top: 32px; }
.history h3 { margin: 0 0 8px; font-size: 16px; }
.history-loading { font-size: 12px; color: #999; font-weight: 400; }
.history ul { list-style: none; padding: 0; }
.history li {
  padding: 6px 0;
  border-bottom: 1px solid #eee;
  font-size: 13px;
}
.history-item {
  display: flex;
  align-items: center;
  gap: 8px;
}
.history-status {
  font-size: 11px;
  font-weight: 600;
  padding: 1px 6px;
  border-radius: 4px;
  text-transform: capitalize;
}
.history-status.completed { background: #dcfce7; color: #16a34a; }
.history-status.failed { background: #fee2e2; color: #dc2626; }
.history-status.cancelled { background: #f3f4f6; color: #6b7280; }
.history-status.transferring { background: #dbeafe; color: #2563eb; }
.history-status.rejected { background: #fef3c7; color: #d97706; }
.history-dir { font-size: 14px; }
.history-size { font-family: monospace; flex: 1; }
.history-time { color: #999; font-size: 12px; }
.history-error { color: #ef4444; cursor: help; }
</style>
