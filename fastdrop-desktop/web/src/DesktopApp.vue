<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import QRCode from 'qrcode'

import AppIcon from './components/AppIcon.vue'
import {
  acceptPair,
  fetchQR,
  getHealth,
  getServerInfo,
  getSettings,
  getTransfer,
  listPairRequests,
  pollPairStatus,
  rejectPair,
  requestDiscoverPair,
  localServiceOrigin,
  updateSettings,
  type PendingPairRequest,
} from './api'
import {
  usePeerPool,
  type PeerHistoryRow,
  type PeerIncomingOffer,
  type PeerTransferProgress,
} from './composables/usePeerPool'
import type { PairAccepted, QRPayload } from './types'

type DesktopPage = 'home' | 'history' | 'received' | 'settings'

interface WSEnvelope {
  type?: string
  payload?: Record<string, unknown>
}

interface IncomingOffer extends PeerIncomingOffer {
  peerId: string
  offerId: string
  transferId: string
  deviceName: string
  files: Array<{
    fileId: string
    name: string
    size: number
    mimeType?: string
    sha256?: string
  }>
}

interface ActiveTransfer {
  peerId: string
  peerName: string
  transferId: string
  fileId: string
  filename: string
  totalBytes: number
  transferredBytes: number
  speedBps: number
  status: string
  error?: string
}

const activePage = ref<DesktopPage>('home')
const dragOver = ref(false)
const uploadStatus = ref('')
const fileInput = ref<HTMLInputElement | null>(null)
const folderInput = ref<HTMLInputElement | null>(null)
const activeTransfers = ref<ActiveTransfer[]>([])
const incomingOffers = ref<IncomingOffer[]>([])
const transfers = ref<PeerHistoryRow[]>([])
const historyLoading = ref(false)
const historyFilter = ref('all')
const historySearch = ref('')
const historyActionError = ref('')

const pendingRequests = ref<PendingPairRequest[]>([])
const showPairDialog = ref(false)
const showConnectPanel = ref(false)
const remoteAddress = ref('')
const remotePairStatus = ref('')
const remotePairing = ref(false)

const qrDataUrl = ref('')
const qrPayload = ref<QRPayload | null>(null)
const qrLoading = ref(false)
const qrError = ref<string | null>(null)
const countdown = ref(0)
const serverName = ref('FastDrop PC')

const settingsDeviceName = ref('')
const settingsDownloadDir = ref('')
const settingsConflictPolicy = ref('rename')
const settingsMdnsEnabled = ref(false)
const settingsRequirePairConfirmation = ref(false)
const settingsRequireReceiveConfirmation = ref(false)
const settingsNetworkName = ref('局域网')
const settingsNetworkType = ref('lan')
const settingsLocalAddresses = ref<string[]>([])
const settingsSaving = ref(false)
const settingsSaved = ref(false)
const settingsError = ref<string | null>(null)

let pairPollTimer: ReturnType<typeof setInterval> | null = null
let qrTimer: ReturnType<typeof setInterval> | null = null
let countdownTimer: ReturnType<typeof setInterval> | null = null
let healthTimer: ReturnType<typeof setInterval> | null = null

const peerPool = usePeerPool({
  onMessage: (peerId, message) => handleWSMessage(peerId, message),
  onProgress: handlePoolProgress,
  onPeerChanged: () => {
    void loadHistory()
  },
  onAuthFailed: (peerId) => {
    incomingOffers.value = incomingOffers.value.filter((offer) => offer.peerId !== peerId)
  },
})

const peerViews = peerPool.peers
const selectedRecipientIds = peerPool.selectedIds
const connectedPeers = computed(() => peerViews.value.filter((peer) => peer.status === 'connected'))
const selectedCount = computed(() => selectedRecipientIds.value.length)
const liveTransfers = computed(() => activeTransfers.value.filter((item) => !isTerminal(item.status)))
const completedTransfers = computed(() => activeTransfers.value.filter((item) => isTerminal(item.status)))
const receivedTransfers = computed(() => transfers.value.filter((item) => item.direction === 'client_to_server'))
const displayedHistory = computed(() => transfers.value.filter((item) => {
  const statusMatch = historyFilter.value === 'all' || item.status === historyFilter.value
  const term = historySearch.value.trim().toLocaleLowerCase()
  if (!term) return statusMatch
  return statusMatch && `${item.peerName || ''} ${item.id} ${item.status}`.toLocaleLowerCase().includes(term)
}))
const serviceAddress = computed(() => {
  if (qrPayload.value) return `${qrPayload.value.host}:${qrPayload.value.port}`
  return '127.0.0.1:9527'
})
const serviceOnline = ref(false)
const desktopNetworkLabel = computed(() => {
  const name = settingsNetworkName.value || (settingsNetworkType.value === 'wifi' ? 'Wi-Fi' : '局域网')
  return name || serviceAddress.value.split(':')[0]
})
const desktopNetworkTitle = computed(() => {
  const addresses = settingsLocalAddresses.value.length
    ? settingsLocalAddresses.value.join(' / ')
    : serviceAddress.value.split(':')[0]
  return `${desktopNetworkLabel.value} · ${addresses}`
})

const navItems: Array<{ id: DesktopPage; label: string; icon: string }> = [
  { id: 'home', label: '首页', icon: 'home' },
  { id: 'history', label: '传输记录', icon: 'history' },
  { id: 'received', label: '接收文件', icon: 'inbox' },
  { id: 'settings', label: '设置', icon: 'settings' },
]

async function checkServiceHealth() {
  try {
    const health = await getHealth()
    serviceOnline.value = health.status === 'ok'
    serverName.value = health.deviceName || serverName.value
  } catch {
    serviceOnline.value = false
  }
}

function selectPage(page: DesktopPage) {
  activePage.value = page
  if (page === 'history' || page === 'received') void loadHistory()
  if (page === 'settings') void loadSettings()
}

async function refreshQR() {
  qrLoading.value = true
  qrError.value = null
  try {
    const payload = await fetchQR()
    qrPayload.value = payload
    serverName.value = payload.serverName
    countdown.value = Math.max(0, payload.expiresAt - Math.floor(Date.now() / 1000))
    qrDataUrl.value = await QRCode.toDataURL(JSON.stringify(payload), {
      width: 280,
      margin: 1,
      color: { dark: '#171A23', light: '#FFFFFF' },
    })
  } catch (error) {
    qrError.value = '无法连接本机 FastDrop 服务'
    console.error(error)
  } finally {
    qrLoading.value = false
  }
}

function tickCountdown() {
  if (countdown.value > 0) countdown.value--
  if (countdown.value === 0 && !qrLoading.value) void refreshQR()
}

function openFilePicker() {
  fileInput.value?.click()
}

function openFolderPicker() {
  folderInput.value?.click()
}

async function handleFilePickerChange(event: Event) {
  const input = event.target as HTMLInputElement
  const files = Array.from(input.files || [])
  input.value = ''
  await sendFiles(files)
}

function handleDragOver(event: DragEvent) {
  event.preventDefault()
  dragOver.value = true
}

function handleDragLeave() {
  dragOver.value = false
}

async function handleDrop(event: DragEvent) {
  event.preventDefault()
  dragOver.value = false
  await sendFiles(Array.from(event.dataTransfer?.files || []))
}

async function sendFiles(files: File[]) {
  if (!files.length) return
  if (!selectedRecipientIds.value.length) {
    uploadStatus.value = '请先选择至少一台在线设备。'
    return
  }
  uploadStatus.value = `正在准备 ${files.length} 个文件…`
  try {
    await peerPool.sendFiles(files, selectedRecipientIds.value)
    uploadStatus.value = `已向 ${selectedRecipientIds.value.length} 台设备发起发送`
    await loadHistory()
  } catch (error) {
    uploadStatus.value = readableError(error)
  }
}

function toggleRecipient(peerId: string) {
  const selected = selectedRecipientIds.value
  selectedRecipientIds.value = selected.includes(peerId)
    ? selected.filter((id) => id !== peerId)
    : [...selected, peerId]
}

function handlePoolProgress(progress: PeerTransferProgress) {
  const existing = activeTransfers.value.find((item) =>
    item.peerId === progress.peerId
      && item.transferId === progress.transferId
      && item.fileId === progress.fileId,
  )
  if (existing) {
    existing.transferredBytes = progress.transferredBytes
    existing.status = progress.status
    existing.error = progress.error
    return
  }
  activeTransfers.value.unshift({
    peerId: progress.peerId,
    peerName: progress.peerName,
    transferId: progress.transferId,
    fileId: progress.fileId,
    filename: progress.fileName,
    totalBytes: progress.totalBytes,
    transferredBytes: progress.transferredBytes,
    speedBps: 0,
    status: progress.status,
    error: progress.error,
  })
}

function handleWSMessage(peerId: string, raw: unknown) {
  const message = raw as WSEnvelope
  const payload = message.payload ?? {}
  const transferId = String(payload.transferId || payload.offerId || '')
  switch (message.type) {
    case 'file.offer': {
      if (activeTransfers.value.some((item) => item.peerId === peerId && item.transferId === transferId)) return
      const offer: IncomingOffer = {
        peerId,
        transferId,
        offerId: String(payload.offerId || transferId),
        deviceName: String(payload.deviceName || peerNameFor(peerId)),
        files: (payload.files as IncomingOffer['files']) || [],
      }
      if (settingsRequireReceiveConfirmation.value) {
        incomingOffers.value.push(offer)
      } else {
        void acceptOffer(offer)
      }
      break
    }
    case 'transfer.started':
    case 'transfer.accepted':
    case 'file.offer.accept':
    case 'transfer.resume':
      updateTransferStatus(peerId, transferId, 'transferring')
      break
    case 'transfer.paused':
      updateTransferStatus(peerId, transferId, 'paused')
      break
    case 'transfer.verifying':
      updateTransferStatus(peerId, transferId, 'verifying')
      break
    case 'transfer.rejected':
    case 'file.offer.reject':
      updateTransferStatus(peerId, transferId, 'failed', '对方已拒绝接收')
      break
    case 'transfer.progress': {
      const item = activeTransfers.value.find((entry) => entry.peerId === peerId && entry.transferId === transferId)
      if (item) {
        item.transferredBytes = Number(payload.transferredBytes || item.transferredBytes)
        item.speedBps = Number(payload.speedBps || 0)
        item.status = 'transferring'
      }
      break
    }
    case 'transfer.completed':
      updateTransferStatus(peerId, transferId, 'completed')
      void loadHistory()
      break
    case 'transfer.failed':
      updateTransferStatus(peerId, transferId, 'failed', String(payload.error || payload.reason || '传输失败'))
      void loadHistory()
      break
    case 'transfer.cancelled':
      updateTransferStatus(peerId, transferId, 'cancelled')
      void loadHistory()
      break
    case 'session.revoked':
      peerPool.removePeer(peerId)
      break
  }
}

function updateTransferStatus(peerId: string, transferId: string, status: string, error?: string) {
  for (const item of activeTransfers.value.filter((entry) => entry.peerId === peerId && entry.transferId === transferId)) {
    item.status = status
    item.error = error
    if (status === 'completed') item.transferredBytes = item.totalBytes
  }
}

function pauseTransfer(item: ActiveTransfer) {
  item.status = 'paused'
  peerPool.send(item.peerId, envelope('transfer.pause', item.transferId))
}

function resumeTransfer(item: ActiveTransfer) {
  item.status = 'transferring'
  peerPool.send(item.peerId, envelope('transfer.resume', item.transferId))
}

function cancelTransfer(item: ActiveTransfer) {
  item.status = 'cancelled'
  peerPool.send(item.peerId, envelope('transfer.cancel', item.transferId))
}

function envelope(type: string, transferId: string) {
  return {
    version: 1,
    type,
    messageId: crypto.randomUUID(),
    timestamp: Date.now(),
    payload: { transferId },
  }
}

async function acceptOffer(offer: IncomingOffer) {
  incomingOffers.value = incomingOffers.value.filter((item) => item.transferId !== offer.transferId)
  for (const file of offer.files) {
    activeTransfers.value.unshift({
      peerId: offer.peerId,
      peerName: peerNameFor(offer.peerId),
      transferId: offer.transferId,
      fileId: file.fileId,
      filename: file.name,
      totalBytes: file.size,
      transferredBytes: 0,
      speedBps: 0,
      status: 'transferring',
    })
  }
  try {
    await peerPool.acceptOffer(offer)
    const peer = peerViews.value.find((item) => item.id === offer.peerId)
    if (peer) {
      const row = await getTransfer(offer.transferId, peer)
      if (row.status === 'completed') updateTransferStatus(offer.peerId, offer.transferId, 'completed')
    }
  } catch (error) {
    updateTransferStatus(offer.peerId, offer.transferId, 'failed', readableError(error))
  }
}

function rejectOffer(offer: IncomingOffer) {
  incomingOffers.value = incomingOffers.value.filter((item) => item.transferId !== offer.transferId)
  peerPool.rejectOffer(offer)
}

async function pollPairRequests() {
  try {
    const result = await listPairRequests()
    for (const request of result.requests || []) {
      if (request.status !== 'accepted' || !request.session) continue
      const peerId = `${request.deviceId}::${request.session.sessionId}`
      if (peerViews.value.some((peer) => peer.id === peerId)) continue
      peerPool.addPeer({
        id: peerId,
        name: request.deviceName || '新设备',
        platform: request.platform || 'unknown',
        baseUrl: localServiceOrigin(),
        sessionId: request.session.sessionId,
        accessToken: request.session.accessToken,
        websocketUrl: request.session.websocketUrl,
        role: 'local-session',
      })
    }
    pendingRequests.value = (result.requests || []).filter((item) => item.status === 'waiting_confirmation')
    showPairDialog.value = pendingRequests.value.length > 0
  } catch {
    // The local service may still be starting. The next poll will recover.
  }
}

async function handleAccept(request: PendingPairRequest) {
  try {
    const accepted = await acceptPair(request.requestId)
    peerPool.addPeer({
      id: `${request.deviceId}::${accepted.session.sessionId}`,
      name: request.deviceName || '新设备',
      platform: request.platform || 'unknown',
      baseUrl: localServiceOrigin(),
      sessionId: accepted.session.sessionId,
      accessToken: accepted.session.accessToken,
      websocketUrl: accepted.session.websocketUrl,
      role: 'local-session',
    })
    pendingRequests.value = pendingRequests.value.filter((item) => item.requestId !== request.requestId)
    showPairDialog.value = pendingRequests.value.length > 0
  } catch (error) {
    remotePairStatus.value = readableError(error)
  }
}

async function handleReject(requestId: string) {
  await rejectPair(requestId)
  pendingRequests.value = pendingRequests.value.filter((item) => item.requestId !== requestId)
  showPairDialog.value = pendingRequests.value.length > 0
}

async function connectRemotePeer() {
  const input = remoteAddress.value.trim()
  if (!input || remotePairing.value) return
  remotePairing.value = true
  remotePairStatus.value = '正在连接…'
  try {
    const baseUrl = normalizePeerUrl(input)
    const remote = await getServerInfo(baseUrl)
    const request = await requestDiscoverPair(baseUrl, {
      deviceId: localClientId(),
      deviceName: serverName.value,
      platform: 'windows',
      appVersion: '1.0.0',
    })
    const deadline = Date.now() + 35_000
    while (Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 800))
      const result = await pollPairStatus(request.requestId, baseUrl)
      if (result.status === 'accepted' && 'session' in result) {
        const accepted = result as PairAccepted
        peerPool.addPeer({
          id: `${remote.deviceId}@${baseUrl}`,
          name: accepted.server.deviceName || remote.name,
          platform: accepted.server.platform || remote.platform,
          baseUrl,
          sessionId: accepted.session.sessionId,
          accessToken: accepted.session.accessToken,
          websocketUrl: accepted.session.websocketUrl,
          role: 'remote-server',
        })
        remoteAddress.value = ''
        remotePairStatus.value = `已连接 ${accepted.server.deviceName || remote.name}`
        showConnectPanel.value = false
        return
      }
      if (result.status === 'rejected' || result.status === 'expired') {
        throw new Error(result.status === 'rejected' ? '对方拒绝了连接请求' : '连接请求已过期')
      }
    }
    throw new Error('等待连接超时')
  } catch (error) {
    remotePairStatus.value = readableError(error)
  } finally {
    remotePairing.value = false
  }
}

async function loadHistory() {
  historyLoading.value = true
  try {
    transfers.value = await peerPool.loadHistory()
  } finally {
    historyLoading.value = false
  }
}

function canRevealTransfer(item: PeerHistoryRow): boolean {
  return item.peerRole === 'local-session'
    && item.direction === 'client_to_server'
    && item.status === 'completed'
    && Boolean(window.go?.main?.DesktopBridge)
}

async function revealTransfer(item: PeerHistoryRow) {
  const bridge = window.go?.main?.DesktopBridge
  if (!bridge) {
    historyActionError.value = '请在 FastDrop Windows 桌面应用中打开文件位置。'
    return
  }
  historyActionError.value = ''
  try {
    await bridge.RevealTransfer(item.id)
  } catch (error) {
    historyActionError.value = readableError(error)
  }
}

async function loadSettings() {
  try {
    const settings = await getSettings()
    settingsDeviceName.value = settings.deviceName
    settingsDownloadDir.value = settings.downloadDirectory
    settingsConflictPolicy.value = settings.conflictPolicy
    settingsMdnsEnabled.value = settings.mdnsEnabled
    settingsRequirePairConfirmation.value = settings.requirePairConfirmation
    settingsRequireReceiveConfirmation.value = settings.requireReceiveConfirmation
    settingsNetworkName.value = settings.networkName
    settingsNetworkType.value = settings.networkType
    settingsLocalAddresses.value = settings.localAddresses || []
    serverName.value = settings.deviceName
  } catch (error) {
    settingsError.value = readableError(error)
  }
}

async function saveSettings() {
  if (!settingsDeviceName.value.trim() || !settingsDownloadDir.value.trim()) return
  settingsSaving.value = true
  settingsSaved.value = false
  settingsError.value = null
  try {
    const settings = await updateSettings({
      deviceName: settingsDeviceName.value.trim(),
      downloadDirectory: settingsDownloadDir.value.trim(),
      conflictPolicy: settingsConflictPolicy.value,
      mdnsEnabled: settingsMdnsEnabled.value,
      requirePairConfirmation: settingsRequirePairConfirmation.value,
      requireReceiveConfirmation: settingsRequireReceiveConfirmation.value,
    })
    settingsDeviceName.value = settings.deviceName
    settingsDownloadDir.value = settings.downloadDirectory
    serverName.value = settings.deviceName
    settingsSaved.value = true
    window.setTimeout(() => { settingsSaved.value = false }, 1800)
    await refreshQR()
  } catch (error) {
    settingsError.value = readableError(error)
  } finally {
    settingsSaving.value = false
  }
}

async function copyDownloadPath() {
  await navigator.clipboard.writeText(settingsDownloadDir.value)
  settingsSaved.value = true
  window.setTimeout(() => { settingsSaved.value = false }, 1200)
}

async function refreshDesktopState() {
  await Promise.all([checkServiceHealth(), pollPairRequests(), loadHistory(), loadSettings()])
  if (serviceOnline.value) await refreshQR()
}

function normalizePeerUrl(input: string): string {
  const withScheme = /^https?:\/\//i.test(input) ? input : `http://${input}`
  const url = new URL(withScheme)
  if (!url.port) url.port = '9527'
  return url.origin
}

function localClientId(): string {
  const key = 'fastdrop_pc_client_id'
  const existing = localStorage.getItem(key)
  if (existing) return existing
  const id = crypto.randomUUID()
  localStorage.setItem(key, id)
  return id
}

function peerNameFor(peerId: string): string {
  return peerViews.value.find((peer) => peer.id === peerId)?.name || '未知设备'
}

function isTerminal(status: string): boolean {
  return ['completed', 'failed', 'cancelled', 'rejected'].includes(status)
}

function progressPercent(item: ActiveTransfer): number {
  if (item.totalBytes <= 0) return 0
  return Math.min(100, Math.round(item.transferredBytes / item.totalBytes * 100))
}

function formatSize(bytes: number): string {
  if (bytes >= 1_073_741_824) return `${(bytes / 1_073_741_824).toFixed(1)} GB`
  if (bytes >= 1_048_576) return `${(bytes / 1_048_576).toFixed(1)} MB`
  if (bytes >= 1024) return `${(bytes / 1024).toFixed(0)} KB`
  return `${bytes} B`
}

function formatSpeed(bytes: number): string {
  return bytes > 0 ? `${formatSize(bytes)}/s` : ''
}

function formatDate(unixSeconds: number): string {
  return new Intl.DateTimeFormat('zh-CN', {
    month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit',
  }).format(new Date(unixSeconds * 1000))
}

function statusLabel(status: string): string {
  const labels: Record<string, string> = {
    created: '已创建', waiting_accept: '等待接收', preparing: '准备中',
    transferring: '传输中', paused: '已暂停', verifying: '校验中',
    completed: '已完成', failed: '失败', cancelled: '已取消', rejected: '已拒绝',
  }
  return labels[status] || status
}

function readableError(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error)
  const labels: Record<string, string> = {
    SESSION_INVALID: '连接会话已失效，请重新连接设备',
    INSUFFICIENT_STORAGE: '接收设备空间不足',
    FILE_HASH_MISMATCH: '文件校验失败，请重试',
  }
  return labels[message] || message || '操作失败，请重试'
}

onMounted(async () => {
  peerPool.restore()
  await Promise.all([loadSettings(), checkServiceHealth()])
  await Promise.all([refreshQR(), loadHistory(), pollPairRequests()])
  pairPollTimer = setInterval(pollPairRequests, 2000)
  qrTimer = setInterval(refreshQR, 50_000)
  countdownTimer = setInterval(tickCountdown, 1000)
  healthTimer = setInterval(checkServiceHealth, 5000)
})

onUnmounted(() => {
  if (pairPollTimer) clearInterval(pairPollTimer)
  if (qrTimer) clearInterval(qrTimer)
  if (countdownTimer) clearInterval(countdownTimer)
  if (healthTimer) clearInterval(healthTimer)
  peerPool.close()
})
</script>

<template>
  <div class="desktop-shell">
    <aside class="sidebar">
      <div class="brand">
        <div class="brand-mark"><span></span><span></span></div>
        <div>
          <strong>FastDrop</strong>
          <small>局域网文件快传</small>
        </div>
      </div>

      <nav class="side-nav" aria-label="主导航">
        <button
          v-for="item in navItems"
          :key="item.id"
          :class="['nav-item', { active: activePage === item.id }]"
          @click="selectPage(item.id)"
        >
          <AppIcon :name="item.icon" :size="20" />
          <span>{{ item.label }}</span>
          <span v-if="item.id === 'history' && liveTransfers.length" class="nav-count">{{ liveTransfers.length }}</span>
        </button>
      </nav>

      <div class="sidebar-status">
        <div class="service-line">
          <span :class="['status-dot', { online: serviceOnline }]"></span>
          <div><strong>{{ serviceOnline ? '服务运行中' : '服务不可用' }}</strong><small>{{ serviceAddress }}</small><small :title="desktopNetworkTitle">{{ desktopNetworkLabel }}</small></div>
        </div>
        <div class="version-line"><span>FastDrop 1.0.0</span><span>局域网模式</span></div>
      </div>
    </aside>

    <main class="workspace">
      <header class="topbar">
        <div>
          <p class="eyebrow">不登录，不上云，打开就传。</p>
          <h1 v-if="activePage === 'home'">晚上好，{{ serverName }}</h1>
          <h1 v-else-if="activePage === 'history'">传输记录</h1>
          <h1 v-else-if="activePage === 'received'">接收文件</h1>
          <h1 v-else>设置</h1>
        </div>
        <div class="topbar-actions">
          <span class="online-pill"><span class="status-dot online"></span>{{ connectedPeers.length }} 台设备在线</span>
          <button class="icon-button" title="刷新" @click="refreshDesktopState"><AppIcon name="refresh" :size="19" /></button>
        </div>
      </header>

      <section v-if="activePage === 'home'" class="page home-page">
        <div
          :class="['drop-panel', { active: dragOver }]"
          @dragover="handleDragOver"
          @dragleave="handleDragLeave"
          @drop="handleDrop"
        >
          <div class="drop-icon"><AppIcon name="upload" :size="30" /></div>
          <div class="drop-copy">
            <h2>拖放文件或文件夹到这里</h2>
            <p>文件只在局域网内点对点传输，不经过云端。</p>
          </div>
          <div class="drop-actions">
            <button class="primary-button" @click="openFilePicker"><AppIcon name="file" :size="17" />选择文件</button>
            <button class="secondary-button" @click="openFolderPicker"><AppIcon name="folder" :size="17" />选择文件夹</button>
          </div>
          <input ref="fileInput" type="file" multiple hidden @change="handleFilePickerChange" />
          <input ref="folderInput" type="file" multiple webkitdirectory hidden @change="handleFilePickerChange" />
        </div>
        <p v-if="uploadStatus" class="inline-notice">{{ uploadStatus }}</p>

        <div class="section-heading">
          <div><h2>附近设备</h2><p>可多选，同时发送给多台设备</p></div>
          <button class="text-button" @click="showConnectPanel = true"><AppIcon name="plus" :size="17" />添加设备</button>
        </div>

        <div v-if="peerViews.length" class="device-grid">
          <button
            v-for="peer in peerViews"
            :key="peer.id"
            :class="['device-card', { selected: selectedRecipientIds.includes(peer.id), offline: peer.status !== 'connected' }]"
            :disabled="peer.status !== 'connected'"
            @click="toggleRecipient(peer.id)"
          >
            <span class="device-avatar"><AppIcon :name="peer.platform === 'windows' ? 'computer' : 'phone'" :size="26" /></span>
            <span class="device-copy"><strong>{{ peer.name }}</strong><small>{{ peer.platform }} · {{ peer.status === 'connected' ? '已连接' : '连接中断' }}</small></span>
            <span class="device-check"><AppIcon v-if="selectedRecipientIds.includes(peer.id)" name="check" :size="15" /></span>
          </button>
        </div>

        <div v-else class="empty-state compact">
          <div class="empty-icon"><AppIcon name="wifi" :size="28" /></div>
          <div><h3>还没有可发送的设备</h3><p>让另一台设备打开 FastDrop，然后扫码或输入局域网 IP 连接。</p></div>
          <button class="primary-button" @click="showConnectPanel = true">添加设备</button>
        </div>

        <div class="selection-summary">
          <span><strong>{{ selectedCount }}</strong> 台设备已选择</span>
          <span v-if="selectedCount === 0">发送前请选择接收设备</span>
          <span v-else>选择文件后将同时发送</span>
        </div>

        <section v-if="liveTransfers.length || completedTransfers.length" class="transfer-drawer">
          <div class="drawer-heading">
            <div><span class="status-dot online"></span><strong>当前传输</strong><small>{{ liveTransfers.length }} 个进行中</small></div>
            <button class="text-button" @click="selectPage('history')">查看全部</button>
          </div>
          <article v-for="item in activeTransfers.slice(0, 4)" :key="`${item.peerId}:${item.transferId}:${item.fileId}`" class="transfer-row">
            <div class="file-avatar"><AppIcon name="file" :size="20" /></div>
            <div class="transfer-main">
              <div class="transfer-title"><strong>{{ item.filename }}</strong><span>{{ statusLabel(item.status) }}</span></div>
              <div class="progress-track"><span :class="item.status" :style="{ width: `${progressPercent(item)}%` }"></span></div>
              <div class="transfer-meta"><span>到 {{ item.peerName }} · {{ formatSize(item.transferredBytes) }} / {{ formatSize(item.totalBytes) }}</span><span>{{ formatSpeed(item.speedBps) || `${progressPercent(item)}%` }}</span></div>
            </div>
            <div class="row-actions">
              <button v-if="item.status === 'transferring'" class="icon-button" title="暂停" @click="pauseTransfer(item)"><AppIcon name="pause" :size="17" /></button>
              <button v-if="item.status === 'paused'" class="icon-button" title="继续" @click="resumeTransfer(item)"><AppIcon name="play" :size="17" /></button>
              <button v-if="!isTerminal(item.status)" class="icon-button danger" title="取消" @click="cancelTransfer(item)"><AppIcon name="x" :size="17" /></button>
            </div>
          </article>
        </section>
      </section>

      <section v-else-if="activePage === 'history'" class="page">
        <div class="toolbar">
          <div class="segmented-control">
            <button v-for="filter in [['all','全部'],['completed','已完成'],['failed','失败'],['cancelled','已取消']]" :key="filter[0]" :class="{ active: historyFilter === filter[0] }" @click="historyFilter = filter[0]">{{ filter[1] }}</button>
          </div>
          <input v-model="historySearch" class="search-input" placeholder="搜索设备或任务编号" />
        </div>
        <p v-if="historyActionError" class="history-action-error">{{ historyActionError }}</p>
        <div v-if="historyLoading" class="loading-state">正在加载传输记录…</div>
        <div v-else-if="displayedHistory.length" class="history-list">
          <article v-for="item in displayedHistory" :key="`${item.peerId}:${item.id}`" class="history-row">
            <div :class="['history-direction', item.direction === 'client_to_server' ? 'received' : 'sent']"><AppIcon :name="item.direction === 'client_to_server' ? 'inbox' : 'upload'" :size="20" /></div>
            <div class="history-main"><strong>{{ item.totalFiles }} 个文件</strong><span>{{ item.direction === 'client_to_server' ? `来自 ${item.peerName || '设备'}` : `发送到 ${item.peerName || '设备'}` }}</span></div>
            <div class="history-size"><strong>{{ formatSize(item.totalBytes) }}</strong><span>{{ formatDate(item.createdAt) }}</span></div>
            <span :class="['status-badge', item.status]">{{ statusLabel(item.status) }}</span>
            <button v-if="canRevealTransfer(item)" class="history-action-button" title="在资源管理器中显示" @click="revealTransfer(item)"><AppIcon name="folder" :size="15" />打开位置</button>
          </article>
        </div>
        <div v-else class="empty-state page-empty">
          <div class="empty-icon"><AppIcon name="history" :size="30" /></div>
          <div><h3>还没有传输记录</h3><p>发送或接收文件后，任务状态和时间会显示在这里。</p></div>
          <button class="primary-button" @click="selectPage('home')">开始发送</button>
        </div>
      </section>

      <section v-else-if="activePage === 'received'" class="page">
        <div class="received-hero">
          <div class="received-icon"><AppIcon name="folder" :size="28" /></div>
          <div><span>默认接收位置</span><strong>{{ settingsDownloadDir }}</strong></div>
          <button class="secondary-button" @click="copyDownloadPath"><AppIcon name="copy" :size="16" />复制路径</button>
        </div>
        <p v-if="historyActionError" class="history-action-error">{{ historyActionError }}</p>
        <div v-if="receivedTransfers.length" class="history-list">
          <article v-for="item in receivedTransfers" :key="`${item.peerId}:${item.id}`" class="history-row">
            <div class="history-direction received"><AppIcon name="inbox" :size="20" /></div>
            <div class="history-main"><strong>{{ item.totalFiles }} 个接收文件</strong><span>来自 {{ item.peerName || '已配对设备' }}</span></div>
            <div class="history-size"><strong>{{ formatSize(item.totalBytes) }}</strong><span>{{ formatDate(item.createdAt) }}</span></div>
            <span :class="['status-badge', item.status]">{{ statusLabel(item.status) }}</span>
            <button v-if="canRevealTransfer(item)" class="history-action-button" title="在资源管理器中显示" @click="revealTransfer(item)"><AppIcon name="folder" :size="15" />打开位置</button>
          </article>
        </div>
        <div v-else class="empty-state page-empty">
          <div class="empty-icon"><AppIcon name="inbox" :size="30" /></div>
          <div><h3>还没有接收文件</h3><p>其他设备发来的文件会保存到上方目录，并出现在这里。</p></div>
        </div>
      </section>

      <section v-else class="page settings-page">
        <div class="settings-column">
          <section class="settings-card">
            <div class="settings-card-heading"><div class="setting-icon"><AppIcon name="computer" :size="20" /></div><div><h2>本机设备</h2><p>此名称会显示给同一局域网内的其他设备。</p></div></div>
            <label class="field"><span>设备名称</span><input v-model="settingsDeviceName" maxlength="40" /></label>
          </section>

          <section class="settings-card">
            <div class="settings-card-heading"><div class="setting-icon"><AppIcon name="inbox" :size="20" /></div><div><h2>文件接收</h2><p>设置保存位置与重名文件处理方式。</p></div></div>
            <label class="field"><span>接收目录</span><div class="input-action"><input v-model="settingsDownloadDir" /><button class="icon-button" title="复制目录" @click="copyDownloadPath"><AppIcon name="copy" :size="17" /></button></div></label>
            <label class="field"><span>文件重名时</span><select v-model="settingsConflictPolicy"><option value="rename">自动重命名（推荐）</option><option value="overwrite">覆盖原文件</option><option value="skip">跳过文件</option></select></label>
            <label class="toggle-row"><div><strong>接收前需要确认</strong><span>关闭后，来自已配对设备的文件会自动接收。</span></div><input v-model="settingsRequireReceiveConfirmation" type="checkbox" role="switch" /></label>
          </section>

          <section class="settings-card">
            <div class="settings-card-heading"><div class="setting-icon"><AppIcon name="wifi" :size="20" /></div><div><h2>连接与发现</h2><p>FastDrop 只在当前局域网内广播设备信息。</p></div></div>
            <label class="toggle-row"><div><strong>mDNS 自动发现</strong><span>允许附近设备免扫码发现本机。</span></div><input v-model="settingsMdnsEnabled" type="checkbox" role="switch" /></label>
            <label class="toggle-row"><div><strong>配对时需要确认</strong><span>默认关闭；开启后需在本机同意新的配对请求。</span></div><input v-model="settingsRequirePairConfirmation" type="checkbox" role="switch" /></label>
            <div class="setting-detail"><span>当前网络</span><strong>{{ settingsNetworkName || '局域网' }}</strong></div>
            <div class="setting-detail"><span>本机地址</span><code>{{ settingsLocalAddresses.join(' / ') || '未检测到局域网地址' }}</code></div>
            <div class="setting-detail"><span>监听端口</span><code>9527</code></div>
          </section>

          <div class="settings-actions">
            <span v-if="settingsError" class="error-text">{{ settingsError }}</span>
            <span v-else-if="settingsSaved" class="success-text">设置已保存</span>
            <button class="primary-button" :disabled="settingsSaving" @click="saveSettings">{{ settingsSaving ? '保存中…' : '保存设置' }}</button>
          </div>
        </div>
      </section>
    </main>

    <Teleport to="body">
      <div v-if="showConnectPanel" class="modal-overlay" @click.self="showConnectPanel = false">
        <section class="modal-card connect-modal" role="dialog" aria-modal="true" aria-label="添加设备">
          <div class="modal-heading"><div><span class="eyebrow">添加设备</span><h2>连接另一台 FastDrop 设备</h2></div><button class="icon-button" @click="showConnectPanel = false"><AppIcon name="x" :size="19" /></button></div>
          <div class="connect-grid">
            <div class="qr-panel">
              <div v-if="qrLoading && !qrDataUrl" class="qr-placeholder">正在生成二维码…</div>
              <img v-else-if="qrDataUrl" :src="qrDataUrl" alt="FastDrop 配对二维码" />
              <div v-else class="qr-placeholder error-text">{{ qrError }}</div>
              <strong>手机扫码连接这台电脑</strong><span>二维码 {{ countdown }} 秒后刷新</span>
            </div>
            <div class="manual-panel">
              <div class="manual-icon"><AppIcon name="wifi" :size="24" /></div>
              <h3>通过局域网地址连接</h3><p>输入对方显示的 IP 和端口，例如 192.168.1.23:9527。</p>
              <input v-model="remoteAddress" placeholder="192.168.1.23:9527" @keyup.enter="connectRemotePeer" />
              <button class="primary-button full" :disabled="remotePairing" @click="connectRemotePeer">{{ remotePairing ? '连接中…' : '连接设备' }}</button>
              <span v-if="remotePairStatus" class="inline-notice">{{ remotePairStatus }}</span>
            </div>
          </div>
        </section>
      </div>

      <div v-if="showPairDialog && pendingRequests.length" class="modal-overlay">
        <section class="modal-card" role="dialog" aria-modal="true" aria-label="配对请求">
          <div class="modal-heading"><div><span class="eyebrow">新的配对请求</span><h2>是否允许连接？</h2></div></div>
          <article v-for="request in pendingRequests" :key="request.requestId" class="request-row">
            <div class="device-avatar"><AppIcon :name="request.platform === 'windows' ? 'computer' : 'phone'" :size="25" /></div>
            <div><strong>{{ request.deviceName }}</strong><span>{{ request.platform }} · 同一局域网</span></div>
            <div class="request-actions"><button class="tertiary-button danger-text" @click="handleReject(request.requestId)">拒绝</button><button class="primary-button" @click="handleAccept(request)">允许</button></div>
          </article>
        </section>
      </div>

      <div v-if="incomingOffers.length" class="modal-overlay">
        <section class="modal-card" role="dialog" aria-modal="true" aria-label="接收文件">
          <div class="modal-heading"><div><span class="eyebrow">收到文件请求</span><h2>{{ incomingOffers[0].deviceName }} 想发送文件</h2></div></div>
          <ul class="offer-list"><li v-for="file in incomingOffers[0].files" :key="file.fileId"><AppIcon name="file" :size="18" /><span>{{ file.name }}</span><small>{{ formatSize(file.size) }}</small></li></ul>
          <div class="modal-actions"><button class="secondary-button" @click="rejectOffer(incomingOffers[0])">拒绝</button><button class="primary-button" @click="acceptOffer(incomingOffers[0])">接收文件</button></div>
        </section>
      </div>
    </Teleport>
  </div>
</template>

<style src="./desktop.css"></style>
