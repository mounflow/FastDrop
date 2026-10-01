<script setup lang="ts">
import { computed, onMounted, onUnmounted, reactive, ref } from 'vue'
import QRCode from 'qrcode'

import AppIcon from './components/AppIcon.vue'
import {
  acceptPair,
  fetchQR,
  getHealth,
  getNearbyDevices,
  getServerInfo,
  getSettings,
  listLocalDevices,
  listLocalTransferHistory,
  listPairRequests,
  deleteLocalDevice,
  pollPairStatus,
  rejectPair,
  requestDiscoverPair,
  localServiceOrigin,
  updateSettings,
  type LocalDeviceRow,
  type NearbyDevice,
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

interface ActiveTransferFile {
  fileId: string
  name: string
  totalBytes: number
  transferredBytes: number
  status: string
  error?: string
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
  /** 来件（手机→PC）：明细行写"来自 X"而不是"到 X"。 */
  incoming?: boolean
  /** 批次内逐文件明细（多文件批次才有；单文件传输省略）。 */
  files?: ActiveTransferFile[]
  expanded?: boolean
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
    const name = peerNameFor(peerId)
    const deadPeer = peerViews.value.find((item) => item.id === peerId)
    incomingOffers.value = incomingOffers.value.filter((offer) => offer.peerId !== peerId)
    peerPool.removePeer(peerId)
    // 信任设备自动重配对（免确认模式）：本机作为客户端连对端 server 的
    // 会话失效后，自动重走 pair/discover——对端若开启确认仍会弹出确认框，
    // 关闭则无感恢复。local-session 会话属于手机，须由手机端重新发起。
    if (deadPeer?.role === 'remote-server') {
      uploadStatus.value = `${name} 会话已失效，正在自动重新配对…`
      void autoRepairRemotePair(deadPeer.baseUrl, name)
    } else {
      uploadStatus.value = `${name} 会话已失效，请重新添加设备`
    }
  },
})

const peerViews = peerPool.peers
const selectedRecipientIds = peerPool.selectedIds
const connectedPeers = computed(() => peerViews.value.filter((peer) => peer.status === 'connected'))
const liveTransfers = computed(() => activeTransfers.value.filter((item) => !isTerminal(item.status)))
const completedTransfers = computed(() => activeTransfers.value.filter((item) => isTerminal(item.status)))
const receivedTransfers = computed(() => transfers.value.filter((item) => item.direction === 'client_to_server'))
/// 方向筛选（与手机端一致）：全部 / 发送（本机→对方）/ 接收（对方→本机）。
/// 记录里 client_to_server 表示对端传给本机（本机视角=接收）。
const historyDirection = ref<'all' | 'sent' | 'received'>('all')
function isReceived(item: { direction: string }): boolean {
  return item.direction === 'client_to_server'
}
const displayedHistory = computed(() => transfers.value.filter((item) => {
  const statusMatch = historyFilter.value === 'all' || item.status === historyFilter.value
  const directionMatch =
    historyDirection.value === 'all' ||
    (historyDirection.value === 'received' ? isReceived(item) : !isReceived(item))
  if (!statusMatch || !directionMatch) return false
  const term = historySearch.value.trim().toLocaleLowerCase()
  if (!term) return true
  return `${item.peerName || ''} ${item.id} ${item.status}`.toLocaleLowerCase().includes(term)
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
    // Back off before the countdown-driven retry so a down service is not
    // hammered once per second.
    countdown.value = Math.max(countdown.value, 10)
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
    const { sent, skipped } = await peerPool.sendFiles(files, selectedRecipientIds.value)
    const skippedNote = skipped.length
      ? `（跳过：${skipped.map((peer) => peer.name).join('、')} 不在线）`
      : ''
    uploadStatus.value =
      `已开始向 ${sent.length} 台设备发送 ${files.length} 个文件${skippedNote}`
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
  // 卡片身份统一按 transferId（与来件卡片一致）——否则同一传输可能被
  // 建出两张卡：轮询/WS 的 peerId 不同、transferId 相同。
  let item: ActiveTransfer | undefined = activeTransfers.value.find(
    (entry) => entry.transferId === progress.transferId,
  )
  // 多文件批次：卡片进度必须是**整批**的（逐文件快照求和），否则进度条
  // 显示的是当前单个文件的进度（用户实测反馈）。
  const files = progress.files?.map((file) => ({ ...file }))
  const isBatch = (files?.length ?? 0) > 1
  const batchTransferred = isBatch
    ? files!.reduce((sum, file) => sum + (file.transferredBytes || 0), 0)
    : progress.transferredBytes
  const batchTotal = isBatch
    ? files!.reduce((sum, file) => sum + (file.totalBytes || 0), 0)
    : progress.totalBytes
  const batchSpeed = sampleOutgoingSpeed(progress.transferId, batchTransferred)

  if (!item) {
    item = reactive({
      peerId: progress.peerId,
      peerName: progress.peerName,
      transferId: progress.transferId,
      fileId: progress.fileId,
      filename: isBatch ? `${files!.length} 个文件` : progress.fileName,
      totalBytes: batchTotal,
      transferredBytes: batchTransferred,
      speedBps: batchSpeed,
      status: progress.status,
      error: progress.error,
      files,
      expanded: false,
    })
    activeTransfers.value.unshift(item)
    return
  }
  item.transferredBytes = batchTransferred
  item.totalBytes = batchTotal
  item.speedBps = batchSpeed
  item.filename = isBatch ? `${files!.length} 个文件` : progress.fileName || item.filename
  item.status = progress.status
  item.error = progress.error
  if (files) {
    item.files = files
  }
}

/// 出向批次速率：按整批字节差采样（与手机端一致），比逐文件瞬时速率稳定。
const outgoingSamples = new Map<string, { bytes: number; at: number }>()
function sampleOutgoingSpeed(transferId: string, bytes: number): number {
  const now = Date.now()
  const previous = outgoingSamples.get(transferId)
  outgoingSamples.set(transferId, { bytes, at: now })
  if (!previous) return 0
  const elapsed = now - previous.at
  const delta = bytes - previous.bytes
  if (elapsed < 400 || delta <= 0) return 0
  return Math.round((delta * 1000) / elapsed)
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
    case 'transfer.resume': {
      ensureIncomingCard(peerId, transferId)
      updateTransferStatus(peerId, transferId, 'transferring')
      break
    }
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
      // 来件方向（手机→PC）此前从不创建卡片，传输进行中 PC 首页无感知。
      const item = ensureIncomingCard(peerId, transferId)
      // 卡片字节数由**批次级**数据源驱动：出向来自 emitSnapshot（整批
      // 快照求和）、来向来自本机传输记录轮询。WS 的 transfer.progress 是
      // **单文件**进度，若用它覆盖，进度条会在"单文件刻度"与"整批刻度"
      // 之间来回跳（用户实测：时而是单个文件、时而是总文件）。
      const batchDriven = item.incoming === true || (item.files?.length ?? 0) > 1
      if (!batchDriven) {
        item.totalBytes = Number(payload.totalBytes || item.totalBytes)
        item.transferredBytes = Number(payload.transferredBytes || item.transferredBytes)
        item.speedBps = Number(payload.speedBps || 0)
      }
      if (item.status !== 'paused') item.status = 'transferring'
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

// 来件方向（手机→PC，免确认直传）只会以 WS 事件的形式出现：确保存在
// 一张进度卡片，首页才能实时反映接收进度（否则完成后才见于传输记录）。
function ensureIncomingCard(peerId: string, transferId: string): ActiveTransfer {
  // 按 transferId 唯一：轮询路径用 peerDeviceId、WS 路径用会话派生的 peerId，
  // 两者不同——若把 peerId 计入身份，同一个传输会被画成两张卡片。
  const existing = activeTransfers.value.find(
    (entry) => entry.transferId === transferId,
  )
  if (existing) return existing
  const card: ActiveTransfer = {
    peerId,
    peerName: peerNameFor(peerId),
    transferId,
    fileId: '',
    filename: `来自 ${peerNameFor(peerId)} 的文件`,
    // 方向标记：来件卡片的明细行必须写"来自 X"，不能写"到 X"（此前来件
    // 卡片标题是"来自"、明细却是"到"，自相矛盾）。
    incoming: true,
    totalBytes: 0,
    transferredBytes: 0,
    speedBps: 0,
    status: 'transferring',
  }
  activeTransfers.value.unshift(card)
  return card
}

function toggleTransferExpanded(item: ActiveTransfer) {
  // 单文件没有可展开的明细。
  if (!item.files || item.files.length <= 1) return
  item.expanded = !item.expanded
}

function fileStatusLabel(status: string) {
  const map: Record<string, string> = {
    pending: '等待中',
    transferring: '传输中',
    completed: '已完成',
    failed: '失败',
    paused: '已暂停',
  }
  return map[status] ?? status
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
  peerPool.pauseTransfer(item.peerId, item.transferId)
}

function resumeTransfer(item: ActiveTransfer) {
  item.status = 'transferring'
  peerPool.resumeTransfer(item.peerId, item.transferId)
}

function cancelTransfer(item: ActiveTransfer) {
  item.status = 'cancelled'
  void peerPool.cancelTransfer(item.peerId, item.transferId)
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
  // After accept, progress/state updates arrive via transfer.* WS events
  // (e.g. transfer.completed); the local Go server writes received files.
  try {
    await peerPool.acceptOffer(offer)
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
        deviceId: request.deviceId,
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
      deviceId: request.deviceId,
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

// --- 问题 10: LAN discovery ----------------------------------------------

const nearbyDevices = ref<NearbyDevice[]>([])
const scanningNearby = ref(false)
const nearbyStatus = ref('')

async function scanNearby() {
  if (scanningNearby.value) return
  scanningNearby.value = true
  nearbyStatus.value = '正在扫描局域网…'
  try {
    nearbyDevices.value = await getNearbyDevices()
    nearbyStatus.value = nearbyDevices.value.length
      ? `发现 ${nearbyDevices.value.length} 台设备，点击连接`
      : '未发现附近设备，可让对端打开 FastDrop 后重试，或直接输入 IP'
  } catch (error) {
    nearbyDevices.value = []
    nearbyStatus.value = readableError(error)
  } finally {
    scanningNearby.value = false
  }
}

function openConnectPanel() {
  showConnectPanel.value = true
  void scanNearby()
}

async function connectNearby(device: NearbyDevice) {
  remoteAddress.value = `${device.host}:${device.port}`
  await connectRemotePeer()
}

// --------------------------------------------------------------------------

// 信任设备自动重配对：remote-server 会话失效后自动重走 pair/discover。
// 单次尝试，不循环——失败则提示用户手动重新添加设备。
async function autoRepairRemotePair(baseUrl: string, name: string) {
  try {
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
        const remote = await getServerInfo(baseUrl)
        peerPool.addPeer({
          id: `${remote.deviceId}@${baseUrl}`,
          name: accepted.server.deviceName || remote.name,
          platform: accepted.server.platform || remote.platform,
          baseUrl,
          sessionId: accepted.session.sessionId,
          accessToken: accepted.session.accessToken,
          websocketUrl: accepted.session.websocketUrl,
          role: 'remote-server',
          deviceId: remote.deviceId,
        })
        uploadStatus.value = `已自动重新连接 ${accepted.server.deviceName || remote.name}`
        return
      }
      if (result.status === 'rejected' || result.status === 'expired') break
    }
    uploadStatus.value = `${name} 会话已失效，请重新添加设备`
  } catch (error) {
    uploadStatus.value = `${name} 自动重连失败：${readableError(error)}`
  }
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
          deviceId: remote.deviceId,
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

// 设备能力标签（与手机端三态一致）：本机持有对方会话 = 双向可发送；
// 仅有对方连进来（local-session）= 仅接收。
function peerCapabilityLabel(peer: { role?: string; status?: string }): string {
  if (peer.status !== 'connected') return '离线'
  return peer.role === 'remote-server' ? '双向可发送' : '仅接收（本机尚未取得发送权限）'
}

/// 一台物理设备 = 一行（此前同一台手机的两条连接会显示成"两台设备"，
/// 且都被选中导致重复发送）：
///  - remote-server：本机作为客户端连对方 server → 本机能发送；
///  - local-session：对方连进本机 server → 本机只能接收。
/// 发送目标只取 remote-server 那条（唯一的发送通道），local-session 仅
/// 用于接收能力展示。
interface DeviceRow {
  key: string
  name: string
  platform: string
  label: string
  sendable: boolean
  sendPeerId?: string
  peerIds: string[]
}

const deviceRows = computed<DeviceRow[]>(() => {
  const rows = new Map<string, DeviceRow>()
  for (const peer of peerViews.value) {
    // 设备身份：优先 deviceId，退化到设备名（同一台设备名稳定）。
    const key = peer.deviceId || peer.name
    let row = rows.get(key)
    if (!row) {
      row = {
        key,
        name: peer.name,
        platform: peer.platform,
        label: '离线',
        sendable: false,
        peerIds: [],
      }
      rows.set(key, row)
    }
    row.peerIds.push(peer.id)
    if (peer.role === 'remote-server' && peer.status === 'connected') {
      row.sendable = true
      row.sendPeerId = peer.id
      row.label = '双向可发送'
    } else if (!row.sendable && peer.status === 'connected') {
      row.label = '仅接收（本机尚未取得发送权限）'
    }
  }
  return [...rows.values()]
})

/// 已选择设备数 = 被选中的**可发送设备行**数量（不是原始 peer id 数量：
/// 同一台设备可能有两条连接，此前会显示成"2 台设备已选择"）。
/// 同时过滤掉历史遗留的不可发送 id（local-session）。
const selectedCount = computed(
  () =>
    deviceRows.value.filter(
      (row) => row.sendPeerId && selectedRecipientIds.value.includes(row.sendPeerId),
    ).length,
)

/// 实际会收到文件的 peer id（用于发送前校验/展示），与 sendFiles 的
/// 目标筛选保持一致：只取 remote-server 且每台设备一条。
const effectiveRecipientIds = computed(() =>
  deviceRows.value
    .map((row) => row.sendPeerId)
    .filter((id): id is string => Boolean(id) && selectedRecipientIds.value.includes(id!)),
)

/// 删除一行设备 = 删除该设备的**全部连接**（remote-server 发送通道 +
/// local-session 接收通道），并调用本机路由真正断开（吊销会话 + 忽略标记）。
async function onRemoveRow(row: DeviceRow) {
  const confirmed = window.confirm(
    `与「${row.name}」完全断开？\n\n` +
      '将吊销对方在本机的访问权限并删除配对信息。\n' +
      '删除后不会自动重新连接；需要时请重新配对。\n' +
      '（传输记录不受影响。）',
  )
  if (!confirmed) return
  try {
    // 设备身份：优先 deviceId；退化到用行内任一 peer 的 id 前缀。
    const deviceId =
      row.key ||
      (row.peerIds[0]?.includes('@')
        ? row.peerIds[0].split('@')[0]
        : (row.peerIds[0]?.split('::')[0] ?? ''))
    const result = await deleteLocalDevice(deviceId)
    for (const peerId of row.peerIds) peerPool.removePeer(peerId)
    incomingOffers.value = incomingOffers.value.filter(
      (o) => !row.peerIds.includes(o.peerId),
    )
    uploadStatus.value = `已删除 ${row.name}（吊销 ${result.revokedSessions} 个会话，不再自动重连）`
  } catch (error) {
    uploadStatus.value = `${row.name} 删除失败：${readableError(error)}`
  }
}

async function loadHistory() {
  historyLoading.value = true
  try {
    transfers.value = await peerPool.loadHistory()
    pruneActiveTransfers()
  } finally {
    historyLoading.value = false
  }
}

// Keep the transfer drawer bounded: drop terminal rows already reflected in
// history, then cap the list at the 20 most recent entries.
// 问题 7 收尾：来件（手机→PC）的实时进度不能依赖 WS 会话采纳（配对请求
// 保留期有限，桌面 UI 未必有那条 WS）——直接轮询本机服务的本地传输记录，
// 非终态的接收行渲染成"当前传输"卡片（显示 + 进度），终态交给历史。
let incomingPollBusy = false
/// 来件进度采样（transferId → 上次字节数与采样时刻），用于推算接收速率。
const incomingSamples = new Map<string, { bytes: number; at: number }>()
async function pollIncomingTransfers() {
  if (incomingPollBusy) return
  incomingPollBusy = true
  try {
    const rows = await listLocalTransferHistory()
    let historyDirty = false
    for (const row of rows) {
      if (row.direction !== 'client_to_server' || isTerminal(row.status)) continue
      const item = ensureIncomingCard(row.peerDeviceId, row.id)
      item.peerName = row.peerName || item.peerName
      // 单文件来件显示真实文件名（本地记录里有批次首个文件名）。
      item.filename =
        row.totalFiles > 1
          ? `${row.totalFiles} 个文件`
          : row.firstFileName || '接收文件'
      item.totalBytes = row.totalBytes
      // 来件方向没有 WS 进度事件（接收进度靠轮询），速率由两次采样的
      // 字节差 / 时间差算出——本地传输记录里没有瞬时速率字段。
      const previous = incomingSamples.get(row.id)
      const now = Date.now()
      if (previous && now > previous.at && row.transferredBytes > previous.bytes) {
        const bps = ((row.transferredBytes - previous.bytes) * 1000) / (now - previous.at)
        // 轻度平滑，避免单次采样抖动导致数字乱跳。
        item.speedBps = item.speedBps > 0 ? Math.round(item.speedBps * 0.4 + bps * 0.6) : Math.round(bps)
      }
      incomingSamples.set(row.id, { bytes: row.transferredBytes, at: now })
      item.transferredBytes = row.transferredBytes
      item.status = row.status === 'verifying' ? 'verifying' : 'transferring'
      item.error = row.errorMessage
    }
    // 已变为终态的卡片：标记最终状态并刷新历史（随后由 prune 清理）。
    for (const item of activeTransfers.value) {
      if (isTerminal(item.status)) continue
      const row = rows.find((r) => r.id === item.transferId)
      if (row && isTerminal(row.status)) {
        item.status = row.status
        item.error = row.errorMessage
        item.transferredBytes = row.transferredBytes
        historyDirty = true
      }
    }
    if (historyDirty) void loadHistory()
  } catch {
    // 本机服务重启间隙：下个轮询周期自然恢复。
  } finally {
    incomingPollBusy = false
  }
}

function pruneActiveTransfers() {
  const settledIds = new Set(
    transfers.value
      .filter((row) => isTerminal(row.status))
      .map((row) => row.id),
  )
  activeTransfers.value = activeTransfers.value
    .filter((item) => !(isTerminal(item.status) && settledIds.has(item.transferId)))
    .slice(0, 20)
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
    NETWORK_UNREACHABLE: '无法连接该地址，请检查 IP 和端口',
    'Transfer cancelled': '已取消',
  }
  return labels[message] || message || '操作失败，请重试'
}

// 一次连接 = 双向通道（PC 侧对称实现）。
//
// 会话是"每服务器单向"的：手机配对进 PC 只让手机拿到 PC 的会话，PC 仍缺
// 对方会话、发不了文件。这里轮询本机设备表，对"有地址、未持有有效会话、
// 且未被用户删除"的设备反向走 pair/discover（对端默认免确认）建立双向
// 通道。幂等 + 退避：同设备进行中跳过，失败按 30s/60s/120s 退避。
const pcPairInFlight = new Set<string>()
const pcPairLastAttempt = new Map<string, number>()
const pcPairAttempts = new Map<string, number>()

function pcPairBackoffMs(deviceId: string): number {
  const n = pcPairAttempts.get(deviceId) ?? 0
  if (n <= 1) return 30_000
  if (n === 2) return 60_000
  return 120_000
}

async function ensureMutualSessionWithDevices() {
  let devices: LocalDeviceRow[] = []
  try {
    devices = await listLocalDevices()
  } catch {
    return // 服务未就绪：下次轮询再试
  }
  for (const device of devices) {
    // 已被用户删除（ignored）→ 不自动回连：用户主动执行的结果必须被尊重。
    if (device.ignored) continue
    if (!device.lastIp) continue
    // 环回/本机地址不参与回连（历史测试残留行可能出现 127.0.0.1，
    // 否则会自己连自己）。
    if (
      device.lastIp.startsWith('127.') ||
      device.lastIp === '::1' ||
      device.lastIp === 'localhost'
    ) {
      continue
    }

    // 判定"本机能否发送给对方"的正确信号：本机在**对方服务器**上的会话
    // 是否可用，即 peerPool 中该 peer 的 WS 是否处于已连接状态
    // （注意 /local/devices 的 hasActiveSession 是反方向——对方在本机的
    // 会话，那是"对方能否发给本机"）。
    const livePeer = peerViews.value.find(
      (p) =>
        p.name === device.deviceName ||
        (device.lastIp ? p.baseUrl.includes(device.lastIp) : false),
    )
    if (livePeer && livePeer.status === 'connected') continue

    const last = pcPairLastAttempt.get(device.deviceId) ?? 0
    if (Date.now() - last < pcPairBackoffMs(device.deviceId)) continue
    if (pcPairInFlight.has(device.deviceId)) continue

    pcPairInFlight.add(device.deviceId)
    pcPairLastAttempt.set(device.deviceId, Date.now())
    pcPairAttempts.set(
      device.deviceId,
      (pcPairAttempts.get(device.deviceId) ?? 0) + 1,
    )
    const baseUrl = `http://${device.lastIp}:9527`
    try {
      await autoRepairRemotePair(baseUrl, device.deviceName)
      if (
        peerViews.value.some(
          (p) => p.baseUrl === baseUrl && p.status === 'connected',
        )
      ) {
        pcPairAttempts.delete(device.deviceId) // 成功重置退避
      }
    } finally {
      pcPairInFlight.delete(device.deviceId)
    }
  }
}

let incomingPollTimer: ReturnType<typeof setInterval> | null = null
let devicePollTimer: ReturnType<typeof setInterval> | null = null

onMounted(async () => {
  peerPool.restore()
  await Promise.all([loadSettings(), checkServiceHealth()])
  await Promise.all([refreshQR(), loadHistory(), pollPairRequests()])
  pairPollTimer = setInterval(pollPairRequests, 2000)
  qrTimer = setInterval(refreshQR, 50_000)
  countdownTimer = setInterval(tickCountdown, 1000)
  healthTimer = setInterval(checkServiceHealth, 5000)
  // 问题 7 关联：来件（手机→PC）的实时进度不依赖 WS 会话采纳——直接轮询
  // 本机服务的本地传输记录，让"当前传输"区始终能显示接收进度。
  incomingPollTimer = setInterval(() => { void pollIncomingTransfers() }, 1500)
  // 双向通道：对"连过本机但本机缺其会话"的设备反向回连（幂等 + 退避）。
  void ensureMutualSessionWithDevices()
  devicePollTimer = setInterval(() => { void ensureMutualSessionWithDevices() }, 5000)
})

onUnmounted(() => {
  if (pairPollTimer) clearInterval(pairPollTimer)
  if (qrTimer) clearInterval(qrTimer)
  if (countdownTimer) clearInterval(countdownTimer)
  if (healthTimer) clearInterval(healthTimer)
  if (incomingPollTimer) clearInterval(incomingPollTimer)
  if (devicePollTimer) clearInterval(devicePollTimer)
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
          <button class="text-button" @click="openConnectPanel"><AppIcon name="plus" :size="17" />添加设备</button>
        </div>

        <div v-if="deviceRows.length" class="device-grid">
          <div v-for="row in deviceRows" :key="row.key" class="device-card-wrap">
            <button
              :class="['device-card', { selected: row.sendPeerId ? selectedRecipientIds.includes(row.sendPeerId) : false, offline: !row.sendable }]"
              :disabled="!row.sendable"
              @click="row.sendPeerId && toggleRecipient(row.sendPeerId)"
            >
              <span class="device-avatar"><AppIcon :name="row.platform === 'windows' ? 'computer' : 'phone'" :size="26" /></span>
              <span class="device-copy"><strong>{{ row.name }}</strong><small>{{ row.platform }} · {{ row.label }}</small></span>
              <span class="device-check"><AppIcon v-if="row.sendPeerId && selectedRecipientIds.includes(row.sendPeerId)" name="check" :size="15" /></span>
            </button>
            <button class="icon-button danger device-remove" title="删除设备（断开双向连接且不再自动重连）" @click="onRemoveRow(row)"><AppIcon name="x" :size="15" /></button>
          </div>
        </div>

        <div v-else class="empty-state compact">
          <div class="empty-icon"><AppIcon name="wifi" :size="28" /></div>
          <div><h3>还没有可发送的设备</h3><p>让另一台设备打开 FastDrop，然后扫码或输入局域网 IP 连接。</p></div>
          <button class="primary-button" @click="openConnectPanel">添加设备</button>
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
          <article v-for="item in activeTransfers.slice(0, 4)" :key="`${item.peerId}:${item.transferId}`" class="transfer-row" :class="{ expandable: (item.files?.length ?? 0) > 1 }" @click="toggleTransferExpanded(item)">
            <div class="file-avatar"><AppIcon name="file" :size="20" /></div>
            <div class="transfer-main">
              <div class="transfer-title"><strong>{{ item.filename }}</strong><span>{{ statusLabel(item.status) }}</span></div>
              <div class="progress-track"><span :class="item.status" :style="{ width: `${progressPercent(item)}%` }"></span></div>
              <div class="transfer-meta"><span>{{ item.incoming ? '来自' : '到' }} {{ item.peerName }} · {{ formatSize(item.transferredBytes) }} / {{ formatSize(item.totalBytes) }}<template v-if="(item.files?.length ?? 0) > 1"> · {{ item.files!.filter((f) => f.status === 'completed').length }}/{{ item.files!.length }} 个文件</template></span><span>{{ formatSpeed(item.speedBps) || `${progressPercent(item)}%` }}</span></div>
              <div v-if="item.expanded && item.files?.length" class="transfer-files" @click.stop>
                <div v-for="file in item.files" :key="file.fileId" class="transfer-file-row">
                  <span class="tf-name" :title="file.name">{{ file.name }}</span>
                  <div class="progress-track mini"><span :class="file.status" :style="{ width: `${file.totalBytes ? (file.transferredBytes / file.totalBytes) * 100 : 0}%` }"></span></div>
                  <span class="tf-status" :class="file.status">{{ fileStatusLabel(file.status) }}</span>
                </div>
              </div>
            </div>
            <div class="row-actions">
              <button v-if="item.status === 'transferring'" class="icon-button" title="暂停" @click.stop="pauseTransfer(item)"><AppIcon name="pause" :size="17" /></button>
              <button v-if="item.status === 'paused'" class="icon-button" title="继续" @click.stop="resumeTransfer(item)"><AppIcon name="play" :size="17" /></button>
              <button v-if="!isTerminal(item.status)" class="icon-button danger" title="取消" @click.stop="cancelTransfer(item)"><AppIcon name="x" :size="17" /></button>
            </div>
          </article>
        </section>
      </section>

      <section v-else-if="activePage === 'history'" class="page">
        <div class="toolbar">
          <div class="segmented-control">
            <button v-for="filter in [['all','全部',''],['sent','发送','upload'],['received','接收','inbox']]" :key="filter[0]" :class="{ active: historyDirection === filter[0] }" @click="historyDirection = filter[0] as 'all' | 'sent' | 'received'">{{ filter[1] }}</button>
          </div>
          <div class="segmented-control">
            <button v-for="filter in [['all','全部状态'],['completed','已完成'],['failed','失败'],['cancelled','已取消']]" :key="filter[0]" :class="{ active: historyFilter === filter[0] }" @click="historyFilter = filter[0]">{{ filter[1] }}</button>
          </div>
          <input v-model="historySearch" class="search-input" placeholder="搜索设备或任务编号" />
        </div>
        <p v-if="historyActionError" class="history-action-error">{{ historyActionError }}</p>
        <div v-if="historyLoading" class="loading-state">正在加载传输记录…</div>
        <div v-else-if="displayedHistory.length" class="history-list">
          <article v-for="item in displayedHistory" :key="`${item.peerId}:${item.id}`" class="history-row">
            <div :class="['history-direction', isReceived(item) ? 'received' : 'sent']"><AppIcon :name="isReceived(item) ? 'inbox' : 'upload'" :size="20" /></div>
            <div class="history-main">
              <strong>
                <span :class="['direction-badge', isReceived(item) ? 'received' : 'sent']">{{ isReceived(item) ? '接收' : '发送' }}</span>
                {{ item.totalFiles }} 个文件
              </strong>
              <span>{{ isReceived(item) ? `来自 ${item.peerName || '设备'}` : `发送到 ${item.peerName || '设备'}` }}</span>
            </div>
            <div class="history-size"><strong>{{ formatSize(item.totalBytes) }}</strong><span>{{ formatDate(item.createdAt) }}</span></div>
            <span :class="['status-badge', item.status]">{{ statusLabel(item.status) }}</span>
            <button v-if="canRevealTransfer(item)" class="history-action-button" title="在资源管理器中显示" @click="revealTransfer(item)"><AppIcon name="folder" :size="15" />打开位置</button>
          </article>
        </div>
        <div v-else class="empty-state page-empty">
          <div class="empty-icon"><AppIcon name="history" :size="30" /></div>
          <div v-if="historyDirection === 'all'"><h3>还没有传输记录</h3><p>发送或接收文件后，任务状态和时间会显示在这里。</p></div>
          <div v-else-if="historyDirection === 'sent'"><h3>没有发送记录</h3><p>切换到「全部」或「接收」查看其它方向的记录。</p></div>
          <div v-else><h3>没有接收记录</h3><p>切换到「全部」或「发送」查看其它方向的记录。</p></div>
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
          <div class="nearby-panel">
            <div class="nearby-heading">
              <h3>附近设备</h3>
              <button class="text-button" :disabled="scanningNearby" @click="scanNearby">{{ scanningNearby ? '扫描中…' : '重新扫描' }}</button>
            </div>
            <span v-if="nearbyStatus" class="inline-notice">{{ nearbyStatus }}</span>
            <ul v-if="nearbyDevices.length" class="nearby-list">
              <li v-for="device in nearbyDevices" :key="device.deviceId">
                <button class="nearby-device" :disabled="remotePairing" @click="connectNearby(device)">
                  <AppIcon :name="device.platform === 'windows' ? 'computer' : 'phone'" :size="18" />
                  <strong>{{ device.deviceName }}</strong>
                  <small>{{ device.host }}:{{ device.port }} · {{ device.platform }}</small>
                </button>
              </li>
            </ul>
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
