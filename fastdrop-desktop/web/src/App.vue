<script setup lang="ts">
import { onMounted, onUnmounted, ref } from 'vue'
import QRCode from 'qrcode'
import {
  completeFile,
  createTransfer,
  fetchQR,
  listTransfers,
  pollPairStatus,
  uploadChunk,
} from './api'
import { useWebSocket } from './composables/useWebSocket'
import type { CreateTransferResult, QRPayload, TransferRow } from './types'

const qrDataUrl = ref<string>('')
const qrPayload = ref<QRPayload | null>(null)
const countdown = ref<number>(0)
const pairRequestId = ref<string | null>(null)
const pairStatus = ref<string>('idle')
const serverName = ref<string>('FastDrop-PC')
const transfers = ref<TransferRow[]>([])
const downloadDir = ref<string>('')
const dragOver = ref(false)
const uploadStatus = ref<string>('')

let qrTimer: ReturnType<typeof setInterval> | null = null
let pollTimer: ReturnType<typeof setInterval> | null = null
let countdownTimer: ReturnType<typeof setInterval> | null = null

async function refreshQR() {
  try {
    const payload = await fetchQR()
    qrPayload.value = payload
    serverName.value = payload.serverName
    countdown.value = Math.max(0, payload.expiresAt - Math.floor(Date.now() / 1000))
    qrDataUrl.value = await QRCode.toDataURL(JSON.stringify(payload), { width: 256 })
  } catch (e) {
    console.error(e)
  }
}

async function pollPair() {
  if (!pairRequestId.value) return
  try {
    const res = await pollPairStatus(pairRequestId.value)
    pairStatus.value = res.status
    if (res.status === 'accepted' || res.status === 'rejected' || res.status === 'expired') {
      if (qrTimer) clearInterval(qrTimer)
      if (pollTimer) clearInterval(pollTimer)
      if (countdownTimer) clearInterval(countdownTimer)
    }
  } catch (e) {
    console.error(e)
  }
}

function tickCountdown() {
  if (countdown.value > 0) countdown.value--
  if (countdown.value === 0 && pairRequestId.value === null) refreshQR()
}

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
  uploadStatus.value = `准备上传 ${files.length} 个文件...`
  // Phase 1: PC -> phone uses server_to_client direction. The complete
  // path depends on the Android client; we only register the transfer
  // and surface an offer over WS to any connected device.
  for (const f of files) {
    try {
      // For demonstration, the file is uploaded as if direction=client_to_server
      // since the server treats it as an inbound batch from this PC. The
      // spec's PC->phone flow goes via file.offer + Range download, which is
      // tracked separately.
      await uploadFileToServer(f)
    } catch (e) {
      uploadStatus.value = `失败：${(e as Error).message}`
    }
  }
}

async function uploadFileToServer(file: File) {
  // Create the transfer batch.
  const createBody = {
    offerId: crypto.randomUUID(),
    direction: 'client_to_server' as const,
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
    uploadStatus.value = `${file.name}: ${i + 1}/${f.totalChunks} 块`
  }
  // Compute SHA-256 of the file (browser crypto).
  const hash = await sha256(file)
  await completeFile(
    `/api/v1/transfers/${res.transferId}/files/${f.fileId}/complete`,
    file.size,
    hash,
  )
  uploadStatus.value = `${file.name} 完成 ✓`
}

async function sha256(file: File): Promise<string> {
  const buf = await file.arrayBuffer()
  const digest = await crypto.subtle.digest('SHA-256', buf)
  return Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, '0')).join('')
}

let wsClient: ReturnType<typeof useWebSocket> | null = null

function setupWS(sessionId: string, accessToken: string, wsUrl: string) {
  wsClient = useWebSocket({
    url: wsUrl,
    sessionId,
    accessToken,
    handlers: {
      onMessage: (msg: any) => {
        // The PC UI listens for incoming file.offer from phones so it can
        // pop an accept dialog. For Phase 1 we auto-accept.
        if (msg?.type === 'file.offer') {
          pairStatus.value = 'incoming-offer'
        }
      },
    },
  })
}

async function loadHistory() {
  try {
    transfers.value = await listTransfers()
  } catch {
    transfers.value = []
  }
}

function cleanup() {
  if (qrTimer) clearInterval(qrTimer)
  if (pollTimer) clearInterval(pollTimer)
  if (countdownTimer) clearInterval(countdownTimer)
  wsClient?.close()
}

onMounted(async () => {
  await refreshQR()
  qrTimer = setInterval(refreshQR, 50_000) // refresh 10s before expiry
  countdownTimer = setInterval(tickCountdown, 1000)
  await loadHistory()
})

onUnmounted(cleanup)
</script>

<template>
  <main class="app">
    <header>
      <h1>FastDrop</h1>
      <p class="server">{{ serverName }}</p>
    </header>

    <section class="qr" v-if="qrPayload">
      <img :src="qrDataUrl" alt="二维码" />
      <p>二维码将在 {{ countdown }} 秒后刷新</p>
      <p class="address">{{ qrPayload.host }}:{{ qrPayload.port }}</p>
    </section>

    <section
      class="dropzone"
      :class="{ active: dragOver }"
      @dragover="handleDragOver"
      @dragleave="handleDragLeave"
      @drop="handleDrop"
    >
      将文件拖到这里发送
    </section>
    <p v-if="uploadStatus" class="status">{{ uploadStatus }}</p>

    <section class="history">
      <h3>历史</h3>
      <ul>
        <li v-for="t in transfers" :key="t.id">
          {{ t.id.slice(0, 8) }} · {{ t.status }} · {{ t.transferredBytes }} / {{ t.totalBytes }}
        </li>
        <li v-if="transfers.length === 0">暂无记录</li>
      </ul>
    </section>
  </main>
</template>

<style scoped>
.app {
  max-width: 480px;
  margin: 0 auto;
  padding: 24px;
  font-family: system-ui, sans-serif;
  color: #222;
}
h1 { margin: 0; font-size: 28px; }
.server { color: #666; margin: 4px 0 24px; }
.qr { text-align: center; margin-bottom: 24px; }
.qr img { width: 256px; height: 256px; border-radius: 12px; border: 1px solid #ddd; }
.address { font-family: monospace; color: #555; }
.dropzone {
  border: 2px dashed #aaa;
  border-radius: 12px;
  padding: 32px;
  text-align: center;
  color: #888;
  transition: all 0.2s;
}
.dropzone.active {
  border-color: #4a90e2;
  background: #eef5fc;
  color: #4a90e2;
}
.status { color: #4a90e2; margin-top: 8px; font-size: 14px; }
.history { margin-top: 32px; }
.history ul { list-style: none; padding: 0; }
.history li { padding: 6px 0; border-bottom: 1px solid #eee; font-family: monospace; font-size: 13px; }
</style>
