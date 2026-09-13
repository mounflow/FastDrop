import { computed, onMounted, onUnmounted, ref } from 'vue';
import QRCode from 'qrcode';
import AppIcon from './components/AppIcon.vue';
import { acceptPair, fetchQR, getHealth, getServerInfo, getSettings, getTransfer, listPairRequests, pollPairStatus, rejectPair, requestDiscoverPair, localServiceOrigin, updateSettings, } from './api';
import { usePeerPool, } from './composables/usePeerPool';
const activePage = ref('home');
const dragOver = ref(false);
const uploadStatus = ref('');
const fileInput = ref(null);
const folderInput = ref(null);
const activeTransfers = ref([]);
const incomingOffers = ref([]);
const transfers = ref([]);
const historyLoading = ref(false);
const historyFilter = ref('all');
const historySearch = ref('');
const historyActionError = ref('');
const pendingRequests = ref([]);
const showPairDialog = ref(false);
const showConnectPanel = ref(false);
const remoteAddress = ref('');
const remotePairStatus = ref('');
const remotePairing = ref(false);
const qrDataUrl = ref('');
const qrPayload = ref(null);
const qrLoading = ref(false);
const qrError = ref(null);
const countdown = ref(0);
const serverName = ref('FastDrop PC');
const settingsDeviceName = ref('');
const settingsDownloadDir = ref('');
const settingsConflictPolicy = ref('rename');
const settingsMdnsEnabled = ref(false);
const settingsRequirePairConfirmation = ref(false);
const settingsRequireReceiveConfirmation = ref(false);
const settingsNetworkName = ref('局域网');
const settingsNetworkType = ref('lan');
const settingsLocalAddresses = ref([]);
const settingsSaving = ref(false);
const settingsSaved = ref(false);
const settingsError = ref(null);
let pairPollTimer = null;
let qrTimer = null;
let countdownTimer = null;
let healthTimer = null;
const peerPool = usePeerPool({
    onMessage: (peerId, message) => handleWSMessage(peerId, message),
    onProgress: handlePoolProgress,
    onPeerChanged: () => {
        void loadHistory();
    },
    onAuthFailed: (peerId) => {
        incomingOffers.value = incomingOffers.value.filter((offer) => offer.peerId !== peerId);
    },
});
const peerViews = peerPool.peers;
const selectedRecipientIds = peerPool.selectedIds;
const connectedPeers = computed(() => peerViews.value.filter((peer) => peer.status === 'connected'));
const selectedCount = computed(() => selectedRecipientIds.value.length);
const liveTransfers = computed(() => activeTransfers.value.filter((item) => !isTerminal(item.status)));
const completedTransfers = computed(() => activeTransfers.value.filter((item) => isTerminal(item.status)));
const receivedTransfers = computed(() => transfers.value.filter((item) => item.direction === 'client_to_server'));
const displayedHistory = computed(() => transfers.value.filter((item) => {
    const statusMatch = historyFilter.value === 'all' || item.status === historyFilter.value;
    const term = historySearch.value.trim().toLocaleLowerCase();
    if (!term)
        return statusMatch;
    return statusMatch && `${item.peerName || ''} ${item.id} ${item.status}`.toLocaleLowerCase().includes(term);
}));
const serviceAddress = computed(() => {
    if (qrPayload.value)
        return `${qrPayload.value.host}:${qrPayload.value.port}`;
    return '127.0.0.1:9527';
});
const serviceOnline = ref(false);
const desktopNetworkLabel = computed(() => {
    const name = settingsNetworkName.value || (settingsNetworkType.value === 'wifi' ? 'Wi-Fi' : '局域网');
    return name || serviceAddress.value.split(':')[0];
});
const desktopNetworkTitle = computed(() => {
    const addresses = settingsLocalAddresses.value.length
        ? settingsLocalAddresses.value.join(' / ')
        : serviceAddress.value.split(':')[0];
    return `${desktopNetworkLabel.value} · ${addresses}`;
});
const navItems = [
    { id: 'home', label: '首页', icon: 'home' },
    { id: 'history', label: '传输记录', icon: 'history' },
    { id: 'received', label: '接收文件', icon: 'inbox' },
    { id: 'settings', label: '设置', icon: 'settings' },
];
async function checkServiceHealth() {
    try {
        const health = await getHealth();
        serviceOnline.value = health.status === 'ok';
        serverName.value = health.deviceName || serverName.value;
    }
    catch {
        serviceOnline.value = false;
    }
}
function selectPage(page) {
    activePage.value = page;
    if (page === 'history' || page === 'received')
        void loadHistory();
    if (page === 'settings')
        void loadSettings();
}
async function refreshQR() {
    qrLoading.value = true;
    qrError.value = null;
    try {
        const payload = await fetchQR();
        qrPayload.value = payload;
        serverName.value = payload.serverName;
        countdown.value = Math.max(0, payload.expiresAt - Math.floor(Date.now() / 1000));
        qrDataUrl.value = await QRCode.toDataURL(JSON.stringify(payload), {
            width: 280,
            margin: 1,
            color: { dark: '#171A23', light: '#FFFFFF' },
        });
    }
    catch (error) {
        qrError.value = '无法连接本机 FastDrop 服务';
        console.error(error);
    }
    finally {
        qrLoading.value = false;
    }
}
function tickCountdown() {
    if (countdown.value > 0)
        countdown.value--;
    if (countdown.value === 0 && !qrLoading.value)
        void refreshQR();
}
function openFilePicker() {
    fileInput.value?.click();
}
function openFolderPicker() {
    folderInput.value?.click();
}
async function handleFilePickerChange(event) {
    const input = event.target;
    const files = Array.from(input.files || []);
    input.value = '';
    await sendFiles(files);
}
function handleDragOver(event) {
    event.preventDefault();
    dragOver.value = true;
}
function handleDragLeave() {
    dragOver.value = false;
}
async function handleDrop(event) {
    event.preventDefault();
    dragOver.value = false;
    await sendFiles(Array.from(event.dataTransfer?.files || []));
}
async function sendFiles(files) {
    if (!files.length)
        return;
    if (!selectedRecipientIds.value.length) {
        uploadStatus.value = '请先选择至少一台在线设备。';
        return;
    }
    uploadStatus.value = `正在准备 ${files.length} 个文件…`;
    try {
        await peerPool.sendFiles(files, selectedRecipientIds.value);
        uploadStatus.value = `已向 ${selectedRecipientIds.value.length} 台设备发起发送`;
        await loadHistory();
    }
    catch (error) {
        uploadStatus.value = readableError(error);
    }
}
function toggleRecipient(peerId) {
    const selected = selectedRecipientIds.value;
    selectedRecipientIds.value = selected.includes(peerId)
        ? selected.filter((id) => id !== peerId)
        : [...selected, peerId];
}
function handlePoolProgress(progress) {
    const existing = activeTransfers.value.find((item) => item.peerId === progress.peerId
        && item.transferId === progress.transferId
        && item.fileId === progress.fileId);
    if (existing) {
        existing.transferredBytes = progress.transferredBytes;
        existing.status = progress.status;
        existing.error = progress.error;
        return;
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
    });
}
function handleWSMessage(peerId, raw) {
    const message = raw;
    const payload = message.payload ?? {};
    const transferId = String(payload.transferId || payload.offerId || '');
    switch (message.type) {
        case 'file.offer': {
            if (activeTransfers.value.some((item) => item.peerId === peerId && item.transferId === transferId))
                return;
            const offer = {
                peerId,
                transferId,
                offerId: String(payload.offerId || transferId),
                deviceName: String(payload.deviceName || peerNameFor(peerId)),
                files: payload.files || [],
            };
            if (settingsRequireReceiveConfirmation.value) {
                incomingOffers.value.push(offer);
            }
            else {
                void acceptOffer(offer);
            }
            break;
        }
        case 'transfer.started':
        case 'transfer.accepted':
        case 'file.offer.accept':
        case 'transfer.resume':
            updateTransferStatus(peerId, transferId, 'transferring');
            break;
        case 'transfer.paused':
            updateTransferStatus(peerId, transferId, 'paused');
            break;
        case 'transfer.verifying':
            updateTransferStatus(peerId, transferId, 'verifying');
            break;
        case 'transfer.rejected':
        case 'file.offer.reject':
            updateTransferStatus(peerId, transferId, 'failed', '对方已拒绝接收');
            break;
        case 'transfer.progress': {
            const item = activeTransfers.value.find((entry) => entry.peerId === peerId && entry.transferId === transferId);
            if (item) {
                item.transferredBytes = Number(payload.transferredBytes || item.transferredBytes);
                item.speedBps = Number(payload.speedBps || 0);
                if (item.status !== 'paused')
                    item.status = 'transferring';
            }
            break;
        }
        case 'transfer.completed':
            updateTransferStatus(peerId, transferId, 'completed');
            void loadHistory();
            break;
        case 'transfer.failed':
            updateTransferStatus(peerId, transferId, 'failed', String(payload.error || payload.reason || '传输失败'));
            void loadHistory();
            break;
        case 'transfer.cancelled':
            updateTransferStatus(peerId, transferId, 'cancelled');
            void loadHistory();
            break;
        case 'session.revoked':
            peerPool.removePeer(peerId);
            break;
    }
}
function updateTransferStatus(peerId, transferId, status, error) {
    for (const item of activeTransfers.value.filter((entry) => entry.peerId === peerId && entry.transferId === transferId)) {
        item.status = status;
        item.error = error;
        if (status === 'completed')
            item.transferredBytes = item.totalBytes;
    }
}
function pauseTransfer(item) {
    item.status = 'paused';
    peerPool.pauseTransfer(item.peerId, item.transferId);
}
function resumeTransfer(item) {
    item.status = 'transferring';
    peerPool.resumeTransfer(item.peerId, item.transferId);
}
function cancelTransfer(item) {
    item.status = 'cancelled';
    peerPool.send(item.peerId, envelope('transfer.cancel', item.transferId));
}
function envelope(type, transferId) {
    return {
        version: 1,
        type,
        messageId: crypto.randomUUID(),
        timestamp: Date.now(),
        payload: { transferId },
    };
}
async function acceptOffer(offer) {
    incomingOffers.value = incomingOffers.value.filter((item) => item.transferId !== offer.transferId);
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
        });
    }
    try {
        await peerPool.acceptOffer(offer);
        const peer = peerViews.value.find((item) => item.id === offer.peerId);
        if (peer) {
            const row = await getTransfer(offer.transferId, peer);
            if (row.status === 'completed')
                updateTransferStatus(offer.peerId, offer.transferId, 'completed');
        }
    }
    catch (error) {
        updateTransferStatus(offer.peerId, offer.transferId, 'failed', readableError(error));
    }
}
function rejectOffer(offer) {
    incomingOffers.value = incomingOffers.value.filter((item) => item.transferId !== offer.transferId);
    peerPool.rejectOffer(offer);
}
async function pollPairRequests() {
    try {
        const result = await listPairRequests();
        for (const request of result.requests || []) {
            if (request.status !== 'accepted' || !request.session)
                continue;
            const peerId = `${request.deviceId}::${request.session.sessionId}`;
            if (peerViews.value.some((peer) => peer.id === peerId))
                continue;
            peerPool.addPeer({
                id: peerId,
                name: request.deviceName || '新设备',
                platform: request.platform || 'unknown',
                baseUrl: localServiceOrigin(),
                sessionId: request.session.sessionId,
                accessToken: request.session.accessToken,
                websocketUrl: request.session.websocketUrl,
                role: 'local-session',
            });
        }
        pendingRequests.value = (result.requests || []).filter((item) => item.status === 'waiting_confirmation');
        showPairDialog.value = pendingRequests.value.length > 0;
    }
    catch {
        // The local service may still be starting. The next poll will recover.
    }
}
async function handleAccept(request) {
    try {
        const accepted = await acceptPair(request.requestId);
        peerPool.addPeer({
            id: `${request.deviceId}::${accepted.session.sessionId}`,
            name: request.deviceName || '新设备',
            platform: request.platform || 'unknown',
            baseUrl: localServiceOrigin(),
            sessionId: accepted.session.sessionId,
            accessToken: accepted.session.accessToken,
            websocketUrl: accepted.session.websocketUrl,
            role: 'local-session',
        });
        pendingRequests.value = pendingRequests.value.filter((item) => item.requestId !== request.requestId);
        showPairDialog.value = pendingRequests.value.length > 0;
    }
    catch (error) {
        remotePairStatus.value = readableError(error);
    }
}
async function handleReject(requestId) {
    await rejectPair(requestId);
    pendingRequests.value = pendingRequests.value.filter((item) => item.requestId !== requestId);
    showPairDialog.value = pendingRequests.value.length > 0;
}
async function connectRemotePeer() {
    const input = remoteAddress.value.trim();
    if (!input || remotePairing.value)
        return;
    remotePairing.value = true;
    remotePairStatus.value = '正在连接…';
    try {
        const baseUrl = normalizePeerUrl(input);
        const remote = await getServerInfo(baseUrl);
        const request = await requestDiscoverPair(baseUrl, {
            deviceId: localClientId(),
            deviceName: serverName.value,
            platform: 'windows',
            appVersion: '1.0.0',
        });
        const deadline = Date.now() + 35_000;
        while (Date.now() < deadline) {
            await new Promise((resolve) => setTimeout(resolve, 800));
            const result = await pollPairStatus(request.requestId, baseUrl);
            if (result.status === 'accepted' && 'session' in result) {
                const accepted = result;
                peerPool.addPeer({
                    id: `${remote.deviceId}@${baseUrl}`,
                    name: accepted.server.deviceName || remote.name,
                    platform: accepted.server.platform || remote.platform,
                    baseUrl,
                    sessionId: accepted.session.sessionId,
                    accessToken: accepted.session.accessToken,
                    websocketUrl: accepted.session.websocketUrl,
                    role: 'remote-server',
                });
                remoteAddress.value = '';
                remotePairStatus.value = `已连接 ${accepted.server.deviceName || remote.name}`;
                showConnectPanel.value = false;
                return;
            }
            if (result.status === 'rejected' || result.status === 'expired') {
                throw new Error(result.status === 'rejected' ? '对方拒绝了连接请求' : '连接请求已过期');
            }
        }
        throw new Error('等待连接超时');
    }
    catch (error) {
        remotePairStatus.value = readableError(error);
    }
    finally {
        remotePairing.value = false;
    }
}
async function loadHistory() {
    historyLoading.value = true;
    try {
        transfers.value = await peerPool.loadHistory();
    }
    finally {
        historyLoading.value = false;
    }
}
function canRevealTransfer(item) {
    return item.peerRole === 'local-session'
        && item.direction === 'client_to_server'
        && item.status === 'completed'
        && Boolean(window.go?.main?.DesktopBridge);
}
async function revealTransfer(item) {
    const bridge = window.go?.main?.DesktopBridge;
    if (!bridge) {
        historyActionError.value = '请在 FastDrop Windows 桌面应用中打开文件位置。';
        return;
    }
    historyActionError.value = '';
    try {
        await bridge.RevealTransfer(item.id);
    }
    catch (error) {
        historyActionError.value = readableError(error);
    }
}
async function loadSettings() {
    try {
        const settings = await getSettings();
        settingsDeviceName.value = settings.deviceName;
        settingsDownloadDir.value = settings.downloadDirectory;
        settingsConflictPolicy.value = settings.conflictPolicy;
        settingsMdnsEnabled.value = settings.mdnsEnabled;
        settingsRequirePairConfirmation.value = settings.requirePairConfirmation;
        settingsRequireReceiveConfirmation.value = settings.requireReceiveConfirmation;
        settingsNetworkName.value = settings.networkName;
        settingsNetworkType.value = settings.networkType;
        settingsLocalAddresses.value = settings.localAddresses || [];
        serverName.value = settings.deviceName;
    }
    catch (error) {
        settingsError.value = readableError(error);
    }
}
async function saveSettings() {
    if (!settingsDeviceName.value.trim() || !settingsDownloadDir.value.trim())
        return;
    settingsSaving.value = true;
    settingsSaved.value = false;
    settingsError.value = null;
    try {
        const settings = await updateSettings({
            deviceName: settingsDeviceName.value.trim(),
            downloadDirectory: settingsDownloadDir.value.trim(),
            conflictPolicy: settingsConflictPolicy.value,
            mdnsEnabled: settingsMdnsEnabled.value,
            requirePairConfirmation: settingsRequirePairConfirmation.value,
            requireReceiveConfirmation: settingsRequireReceiveConfirmation.value,
        });
        settingsDeviceName.value = settings.deviceName;
        settingsDownloadDir.value = settings.downloadDirectory;
        serverName.value = settings.deviceName;
        settingsSaved.value = true;
        window.setTimeout(() => { settingsSaved.value = false; }, 1800);
        await refreshQR();
    }
    catch (error) {
        settingsError.value = readableError(error);
    }
    finally {
        settingsSaving.value = false;
    }
}
async function copyDownloadPath() {
    await navigator.clipboard.writeText(settingsDownloadDir.value);
    settingsSaved.value = true;
    window.setTimeout(() => { settingsSaved.value = false; }, 1200);
}
async function refreshDesktopState() {
    await Promise.all([checkServiceHealth(), pollPairRequests(), loadHistory(), loadSettings()]);
    if (serviceOnline.value)
        await refreshQR();
}
function normalizePeerUrl(input) {
    const withScheme = /^https?:\/\//i.test(input) ? input : `http://${input}`;
    const url = new URL(withScheme);
    if (!url.port)
        url.port = '9527';
    return url.origin;
}
function localClientId() {
    const key = 'fastdrop_pc_client_id';
    const existing = localStorage.getItem(key);
    if (existing)
        return existing;
    const id = crypto.randomUUID();
    localStorage.setItem(key, id);
    return id;
}
function peerNameFor(peerId) {
    return peerViews.value.find((peer) => peer.id === peerId)?.name || '未知设备';
}
function isTerminal(status) {
    return ['completed', 'failed', 'cancelled', 'rejected'].includes(status);
}
function progressPercent(item) {
    if (item.totalBytes <= 0)
        return 0;
    return Math.min(100, Math.round(item.transferredBytes / item.totalBytes * 100));
}
function formatSize(bytes) {
    if (bytes >= 1_073_741_824)
        return `${(bytes / 1_073_741_824).toFixed(1)} GB`;
    if (bytes >= 1_048_576)
        return `${(bytes / 1_048_576).toFixed(1)} MB`;
    if (bytes >= 1024)
        return `${(bytes / 1024).toFixed(0)} KB`;
    return `${bytes} B`;
}
function formatSpeed(bytes) {
    return bytes > 0 ? `${formatSize(bytes)}/s` : '';
}
function formatDate(unixSeconds) {
    return new Intl.DateTimeFormat('zh-CN', {
        month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit',
    }).format(new Date(unixSeconds * 1000));
}
function statusLabel(status) {
    const labels = {
        created: '已创建', waiting_accept: '等待接收', preparing: '准备中',
        transferring: '传输中', paused: '已暂停', verifying: '校验中',
        completed: '已完成', failed: '失败', cancelled: '已取消', rejected: '已拒绝',
    };
    return labels[status] || status;
}
function readableError(error) {
    const message = error instanceof Error ? error.message : String(error);
    const labels = {
        SESSION_INVALID: '连接会话已失效，请重新连接设备',
        INSUFFICIENT_STORAGE: '接收设备空间不足',
        FILE_HASH_MISMATCH: '文件校验失败，请重试',
    };
    return labels[message] || message || '操作失败，请重试';
}
onMounted(async () => {
    peerPool.restore();
    await Promise.all([loadSettings(), checkServiceHealth()]);
    await Promise.all([refreshQR(), loadHistory(), pollPairRequests()]);
    pairPollTimer = setInterval(pollPairRequests, 2000);
    qrTimer = setInterval(refreshQR, 50_000);
    countdownTimer = setInterval(tickCountdown, 1000);
    healthTimer = setInterval(checkServiceHealth, 5000);
});
onUnmounted(() => {
    if (pairPollTimer)
        clearInterval(pairPollTimer);
    if (qrTimer)
        clearInterval(qrTimer);
    if (countdownTimer)
        clearInterval(countdownTimer);
    if (healthTimer)
        clearInterval(healthTimer);
    peerPool.close();
});
debugger; /* PartiallyEnd: #3632/scriptSetup.vue */
const __VLS_ctx = {};
let __VLS_components;
let __VLS_directives;
// CSS variable injection
// CSS variable injection end
__VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
    ...{ class: "desktop-shell" },
});
__VLS_asFunctionalElement(__VLS_intrinsicElements.aside, __VLS_intrinsicElements.aside)({
    ...{ class: "sidebar" },
});
__VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
    ...{ class: "brand" },
});
__VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
    ...{ class: "brand-mark" },
});
__VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
__VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
__VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({});
__VLS_asFunctionalElement(__VLS_intrinsicElements.strong, __VLS_intrinsicElements.strong)({});
__VLS_asFunctionalElement(__VLS_intrinsicElements.small, __VLS_intrinsicElements.small)({});
__VLS_asFunctionalElement(__VLS_intrinsicElements.nav, __VLS_intrinsicElements.nav)({
    ...{ class: "side-nav" },
    'aria-label': "主导航",
});
for (const [item] of __VLS_getVForSourceType((__VLS_ctx.navItems))) {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
        ...{ onClick: (...[$event]) => {
                __VLS_ctx.selectPage(item.id);
            } },
        key: (item.id),
        ...{ class: (['nav-item', { active: __VLS_ctx.activePage === item.id }]) },
    });
    /** @type {[typeof AppIcon, ]} */ ;
    // @ts-ignore
    const __VLS_0 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
        name: (item.icon),
        size: (20),
    }));
    const __VLS_1 = __VLS_0({
        name: (item.icon),
        size: (20),
    }, ...__VLS_functionalComponentArgsRest(__VLS_0));
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
    (item.label);
    if (item.id === 'history' && __VLS_ctx.liveTransfers.length) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
            ...{ class: "nav-count" },
        });
        (__VLS_ctx.liveTransfers.length);
    }
}
__VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
    ...{ class: "sidebar-status" },
});
__VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
    ...{ class: "service-line" },
});
__VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
    ...{ class: (['status-dot', { online: __VLS_ctx.serviceOnline }]) },
});
__VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({});
__VLS_asFunctionalElement(__VLS_intrinsicElements.strong, __VLS_intrinsicElements.strong)({});
(__VLS_ctx.serviceOnline ? '服务运行中' : '服务不可用');
__VLS_asFunctionalElement(__VLS_intrinsicElements.small, __VLS_intrinsicElements.small)({});
(__VLS_ctx.serviceAddress);
__VLS_asFunctionalElement(__VLS_intrinsicElements.small, __VLS_intrinsicElements.small)({
    title: (__VLS_ctx.desktopNetworkTitle),
});
(__VLS_ctx.desktopNetworkLabel);
__VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
    ...{ class: "version-line" },
});
__VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
__VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
__VLS_asFunctionalElement(__VLS_intrinsicElements.main, __VLS_intrinsicElements.main)({
    ...{ class: "workspace" },
});
__VLS_asFunctionalElement(__VLS_intrinsicElements.header, __VLS_intrinsicElements.header)({
    ...{ class: "topbar" },
});
__VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({});
__VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({
    ...{ class: "eyebrow" },
});
if (__VLS_ctx.activePage === 'home') {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.h1, __VLS_intrinsicElements.h1)({});
    (__VLS_ctx.serverName);
}
else if (__VLS_ctx.activePage === 'history') {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.h1, __VLS_intrinsicElements.h1)({});
}
else if (__VLS_ctx.activePage === 'received') {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.h1, __VLS_intrinsicElements.h1)({});
}
else {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.h1, __VLS_intrinsicElements.h1)({});
}
__VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
    ...{ class: "topbar-actions" },
});
__VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
    ...{ class: "online-pill" },
});
__VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
    ...{ class: "status-dot online" },
});
(__VLS_ctx.connectedPeers.length);
__VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
    ...{ onClick: (__VLS_ctx.refreshDesktopState) },
    ...{ class: "icon-button" },
    title: "刷新",
});
/** @type {[typeof AppIcon, ]} */ ;
// @ts-ignore
const __VLS_3 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
    name: "refresh",
    size: (19),
}));
const __VLS_4 = __VLS_3({
    name: "refresh",
    size: (19),
}, ...__VLS_functionalComponentArgsRest(__VLS_3));
if (__VLS_ctx.activePage === 'home') {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.section, __VLS_intrinsicElements.section)({
        ...{ class: "page home-page" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ onDragover: (__VLS_ctx.handleDragOver) },
        ...{ onDragleave: (__VLS_ctx.handleDragLeave) },
        ...{ onDrop: (__VLS_ctx.handleDrop) },
        ...{ class: (['drop-panel', { active: __VLS_ctx.dragOver }]) },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "drop-icon" },
    });
    /** @type {[typeof AppIcon, ]} */ ;
    // @ts-ignore
    const __VLS_6 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
        name: "upload",
        size: (30),
    }));
    const __VLS_7 = __VLS_6({
        name: "upload",
        size: (30),
    }, ...__VLS_functionalComponentArgsRest(__VLS_6));
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "drop-copy" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.h2, __VLS_intrinsicElements.h2)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "drop-actions" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
        ...{ onClick: (__VLS_ctx.openFilePicker) },
        ...{ class: "primary-button" },
    });
    /** @type {[typeof AppIcon, ]} */ ;
    // @ts-ignore
    const __VLS_9 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
        name: "file",
        size: (17),
    }));
    const __VLS_10 = __VLS_9({
        name: "file",
        size: (17),
    }, ...__VLS_functionalComponentArgsRest(__VLS_9));
    __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
        ...{ onClick: (__VLS_ctx.openFolderPicker) },
        ...{ class: "secondary-button" },
    });
    /** @type {[typeof AppIcon, ]} */ ;
    // @ts-ignore
    const __VLS_12 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
        name: "folder",
        size: (17),
    }));
    const __VLS_13 = __VLS_12({
        name: "folder",
        size: (17),
    }, ...__VLS_functionalComponentArgsRest(__VLS_12));
    __VLS_asFunctionalElement(__VLS_intrinsicElements.input)({
        ...{ onChange: (__VLS_ctx.handleFilePickerChange) },
        ref: "fileInput",
        type: "file",
        multiple: true,
        hidden: true,
    });
    /** @type {typeof __VLS_ctx.fileInput} */ ;
    __VLS_asFunctionalElement(__VLS_intrinsicElements.input)({
        ...{ onChange: (__VLS_ctx.handleFilePickerChange) },
        ref: "folderInput",
        type: "file",
        multiple: true,
        webkitdirectory: true,
        hidden: true,
    });
    /** @type {typeof __VLS_ctx.folderInput} */ ;
    if (__VLS_ctx.uploadStatus) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({
            ...{ class: "inline-notice" },
        });
        (__VLS_ctx.uploadStatus);
    }
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "section-heading" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.h2, __VLS_intrinsicElements.h2)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
        ...{ onClick: (...[$event]) => {
                if (!(__VLS_ctx.activePage === 'home'))
                    return;
                __VLS_ctx.showConnectPanel = true;
            } },
        ...{ class: "text-button" },
    });
    /** @type {[typeof AppIcon, ]} */ ;
    // @ts-ignore
    const __VLS_15 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
        name: "plus",
        size: (17),
    }));
    const __VLS_16 = __VLS_15({
        name: "plus",
        size: (17),
    }, ...__VLS_functionalComponentArgsRest(__VLS_15));
    if (__VLS_ctx.peerViews.length) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "device-grid" },
        });
        for (const [peer] of __VLS_getVForSourceType((__VLS_ctx.peerViews))) {
            __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
                ...{ onClick: (...[$event]) => {
                        if (!(__VLS_ctx.activePage === 'home'))
                            return;
                        if (!(__VLS_ctx.peerViews.length))
                            return;
                        __VLS_ctx.toggleRecipient(peer.id);
                    } },
                key: (peer.id),
                ...{ class: (['device-card', { selected: __VLS_ctx.selectedRecipientIds.includes(peer.id), offline: peer.status !== 'connected' }]) },
                disabled: (peer.status !== 'connected'),
            });
            __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
                ...{ class: "device-avatar" },
            });
            /** @type {[typeof AppIcon, ]} */ ;
            // @ts-ignore
            const __VLS_18 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
                name: (peer.platform === 'windows' ? 'computer' : 'phone'),
                size: (26),
            }));
            const __VLS_19 = __VLS_18({
                name: (peer.platform === 'windows' ? 'computer' : 'phone'),
                size: (26),
            }, ...__VLS_functionalComponentArgsRest(__VLS_18));
            __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
                ...{ class: "device-copy" },
            });
            __VLS_asFunctionalElement(__VLS_intrinsicElements.strong, __VLS_intrinsicElements.strong)({});
            (peer.name);
            __VLS_asFunctionalElement(__VLS_intrinsicElements.small, __VLS_intrinsicElements.small)({});
            (peer.platform);
            (peer.status === 'connected' ? '已连接' : '连接中断');
            __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
                ...{ class: "device-check" },
            });
            if (__VLS_ctx.selectedRecipientIds.includes(peer.id)) {
                /** @type {[typeof AppIcon, ]} */ ;
                // @ts-ignore
                const __VLS_21 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
                    name: "check",
                    size: (15),
                }));
                const __VLS_22 = __VLS_21({
                    name: "check",
                    size: (15),
                }, ...__VLS_functionalComponentArgsRest(__VLS_21));
            }
        }
    }
    else {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "empty-state compact" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "empty-icon" },
        });
        /** @type {[typeof AppIcon, ]} */ ;
        // @ts-ignore
        const __VLS_24 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
            name: "wifi",
            size: (28),
        }));
        const __VLS_25 = __VLS_24({
            name: "wifi",
            size: (28),
        }, ...__VLS_functionalComponentArgsRest(__VLS_24));
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({});
        __VLS_asFunctionalElement(__VLS_intrinsicElements.h3, __VLS_intrinsicElements.h3)({});
        __VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({});
        __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
            ...{ onClick: (...[$event]) => {
                    if (!(__VLS_ctx.activePage === 'home'))
                        return;
                    if (!!(__VLS_ctx.peerViews.length))
                        return;
                    __VLS_ctx.showConnectPanel = true;
                } },
            ...{ class: "primary-button" },
        });
    }
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "selection-summary" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.strong, __VLS_intrinsicElements.strong)({});
    (__VLS_ctx.selectedCount);
    if (__VLS_ctx.selectedCount === 0) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
    }
    else {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
    }
    if (__VLS_ctx.liveTransfers.length || __VLS_ctx.completedTransfers.length) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.section, __VLS_intrinsicElements.section)({
            ...{ class: "transfer-drawer" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "drawer-heading" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({});
        __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
            ...{ class: "status-dot online" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.strong, __VLS_intrinsicElements.strong)({});
        __VLS_asFunctionalElement(__VLS_intrinsicElements.small, __VLS_intrinsicElements.small)({});
        (__VLS_ctx.liveTransfers.length);
        __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
            ...{ onClick: (...[$event]) => {
                    if (!(__VLS_ctx.activePage === 'home'))
                        return;
                    if (!(__VLS_ctx.liveTransfers.length || __VLS_ctx.completedTransfers.length))
                        return;
                    __VLS_ctx.selectPage('history');
                } },
            ...{ class: "text-button" },
        });
        for (const [item] of __VLS_getVForSourceType((__VLS_ctx.activeTransfers.slice(0, 4)))) {
            __VLS_asFunctionalElement(__VLS_intrinsicElements.article, __VLS_intrinsicElements.article)({
                key: (`${item.peerId}:${item.transferId}:${item.fileId}`),
                ...{ class: "transfer-row" },
            });
            __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
                ...{ class: "file-avatar" },
            });
            /** @type {[typeof AppIcon, ]} */ ;
            // @ts-ignore
            const __VLS_27 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
                name: "file",
                size: (20),
            }));
            const __VLS_28 = __VLS_27({
                name: "file",
                size: (20),
            }, ...__VLS_functionalComponentArgsRest(__VLS_27));
            __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
                ...{ class: "transfer-main" },
            });
            __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
                ...{ class: "transfer-title" },
            });
            __VLS_asFunctionalElement(__VLS_intrinsicElements.strong, __VLS_intrinsicElements.strong)({});
            (item.filename);
            __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
            (__VLS_ctx.statusLabel(item.status));
            __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
                ...{ class: "progress-track" },
            });
            __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
                ...{ class: (item.status) },
                ...{ style: ({ width: `${__VLS_ctx.progressPercent(item)}%` }) },
            });
            __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
                ...{ class: "transfer-meta" },
            });
            __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
            (item.peerName);
            (__VLS_ctx.formatSize(item.transferredBytes));
            (__VLS_ctx.formatSize(item.totalBytes));
            __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
            (__VLS_ctx.formatSpeed(item.speedBps) || `${__VLS_ctx.progressPercent(item)}%`);
            __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
                ...{ class: "row-actions" },
            });
            if (item.status === 'transferring') {
                __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
                    ...{ onClick: (...[$event]) => {
                            if (!(__VLS_ctx.activePage === 'home'))
                                return;
                            if (!(__VLS_ctx.liveTransfers.length || __VLS_ctx.completedTransfers.length))
                                return;
                            if (!(item.status === 'transferring'))
                                return;
                            __VLS_ctx.pauseTransfer(item);
                        } },
                    ...{ class: "icon-button" },
                    title: "暂停",
                });
                /** @type {[typeof AppIcon, ]} */ ;
                // @ts-ignore
                const __VLS_30 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
                    name: "pause",
                    size: (17),
                }));
                const __VLS_31 = __VLS_30({
                    name: "pause",
                    size: (17),
                }, ...__VLS_functionalComponentArgsRest(__VLS_30));
            }
            if (item.status === 'paused') {
                __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
                    ...{ onClick: (...[$event]) => {
                            if (!(__VLS_ctx.activePage === 'home'))
                                return;
                            if (!(__VLS_ctx.liveTransfers.length || __VLS_ctx.completedTransfers.length))
                                return;
                            if (!(item.status === 'paused'))
                                return;
                            __VLS_ctx.resumeTransfer(item);
                        } },
                    ...{ class: "icon-button" },
                    title: "继续",
                });
                /** @type {[typeof AppIcon, ]} */ ;
                // @ts-ignore
                const __VLS_33 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
                    name: "play",
                    size: (17),
                }));
                const __VLS_34 = __VLS_33({
                    name: "play",
                    size: (17),
                }, ...__VLS_functionalComponentArgsRest(__VLS_33));
            }
            if (!__VLS_ctx.isTerminal(item.status)) {
                __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
                    ...{ onClick: (...[$event]) => {
                            if (!(__VLS_ctx.activePage === 'home'))
                                return;
                            if (!(__VLS_ctx.liveTransfers.length || __VLS_ctx.completedTransfers.length))
                                return;
                            if (!(!__VLS_ctx.isTerminal(item.status)))
                                return;
                            __VLS_ctx.cancelTransfer(item);
                        } },
                    ...{ class: "icon-button danger" },
                    title: "取消",
                });
                /** @type {[typeof AppIcon, ]} */ ;
                // @ts-ignore
                const __VLS_36 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
                    name: "x",
                    size: (17),
                }));
                const __VLS_37 = __VLS_36({
                    name: "x",
                    size: (17),
                }, ...__VLS_functionalComponentArgsRest(__VLS_36));
            }
        }
    }
}
else if (__VLS_ctx.activePage === 'history') {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.section, __VLS_intrinsicElements.section)({
        ...{ class: "page" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "toolbar" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "segmented-control" },
    });
    for (const [filter] of __VLS_getVForSourceType(([['all', '全部'], ['completed', '已完成'], ['failed', '失败'], ['cancelled', '已取消']]))) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
            ...{ onClick: (...[$event]) => {
                    if (!!(__VLS_ctx.activePage === 'home'))
                        return;
                    if (!(__VLS_ctx.activePage === 'history'))
                        return;
                    __VLS_ctx.historyFilter = filter[0];
                } },
            key: (filter[0]),
            ...{ class: ({ active: __VLS_ctx.historyFilter === filter[0] }) },
        });
        (filter[1]);
    }
    __VLS_asFunctionalElement(__VLS_intrinsicElements.input)({
        ...{ class: "search-input" },
        placeholder: "搜索设备或任务编号",
    });
    (__VLS_ctx.historySearch);
    if (__VLS_ctx.historyActionError) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({
            ...{ class: "history-action-error" },
        });
        (__VLS_ctx.historyActionError);
    }
    if (__VLS_ctx.historyLoading) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "loading-state" },
        });
    }
    else if (__VLS_ctx.displayedHistory.length) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "history-list" },
        });
        for (const [item] of __VLS_getVForSourceType((__VLS_ctx.displayedHistory))) {
            __VLS_asFunctionalElement(__VLS_intrinsicElements.article, __VLS_intrinsicElements.article)({
                key: (`${item.peerId}:${item.id}`),
                ...{ class: "history-row" },
            });
            __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
                ...{ class: (['history-direction', item.direction === 'client_to_server' ? 'received' : 'sent']) },
            });
            /** @type {[typeof AppIcon, ]} */ ;
            // @ts-ignore
            const __VLS_39 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
                name: (item.direction === 'client_to_server' ? 'inbox' : 'upload'),
                size: (20),
            }));
            const __VLS_40 = __VLS_39({
                name: (item.direction === 'client_to_server' ? 'inbox' : 'upload'),
                size: (20),
            }, ...__VLS_functionalComponentArgsRest(__VLS_39));
            __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
                ...{ class: "history-main" },
            });
            __VLS_asFunctionalElement(__VLS_intrinsicElements.strong, __VLS_intrinsicElements.strong)({});
            (item.totalFiles);
            __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
            (item.direction === 'client_to_server' ? `来自 ${item.peerName || '设备'}` : `发送到 ${item.peerName || '设备'}`);
            __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
                ...{ class: "history-size" },
            });
            __VLS_asFunctionalElement(__VLS_intrinsicElements.strong, __VLS_intrinsicElements.strong)({});
            (__VLS_ctx.formatSize(item.totalBytes));
            __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
            (__VLS_ctx.formatDate(item.createdAt));
            __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
                ...{ class: (['status-badge', item.status]) },
            });
            (__VLS_ctx.statusLabel(item.status));
            if (__VLS_ctx.canRevealTransfer(item)) {
                __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
                    ...{ onClick: (...[$event]) => {
                            if (!!(__VLS_ctx.activePage === 'home'))
                                return;
                            if (!(__VLS_ctx.activePage === 'history'))
                                return;
                            if (!!(__VLS_ctx.historyLoading))
                                return;
                            if (!(__VLS_ctx.displayedHistory.length))
                                return;
                            if (!(__VLS_ctx.canRevealTransfer(item)))
                                return;
                            __VLS_ctx.revealTransfer(item);
                        } },
                    ...{ class: "history-action-button" },
                    title: "在资源管理器中显示",
                });
                /** @type {[typeof AppIcon, ]} */ ;
                // @ts-ignore
                const __VLS_42 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
                    name: "folder",
                    size: (15),
                }));
                const __VLS_43 = __VLS_42({
                    name: "folder",
                    size: (15),
                }, ...__VLS_functionalComponentArgsRest(__VLS_42));
            }
        }
    }
    else {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "empty-state page-empty" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "empty-icon" },
        });
        /** @type {[typeof AppIcon, ]} */ ;
        // @ts-ignore
        const __VLS_45 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
            name: "history",
            size: (30),
        }));
        const __VLS_46 = __VLS_45({
            name: "history",
            size: (30),
        }, ...__VLS_functionalComponentArgsRest(__VLS_45));
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({});
        __VLS_asFunctionalElement(__VLS_intrinsicElements.h3, __VLS_intrinsicElements.h3)({});
        __VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({});
        __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
            ...{ onClick: (...[$event]) => {
                    if (!!(__VLS_ctx.activePage === 'home'))
                        return;
                    if (!(__VLS_ctx.activePage === 'history'))
                        return;
                    if (!!(__VLS_ctx.historyLoading))
                        return;
                    if (!!(__VLS_ctx.displayedHistory.length))
                        return;
                    __VLS_ctx.selectPage('home');
                } },
            ...{ class: "primary-button" },
        });
    }
}
else if (__VLS_ctx.activePage === 'received') {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.section, __VLS_intrinsicElements.section)({
        ...{ class: "page" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "received-hero" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "received-icon" },
    });
    /** @type {[typeof AppIcon, ]} */ ;
    // @ts-ignore
    const __VLS_48 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
        name: "folder",
        size: (28),
    }));
    const __VLS_49 = __VLS_48({
        name: "folder",
        size: (28),
    }, ...__VLS_functionalComponentArgsRest(__VLS_48));
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.strong, __VLS_intrinsicElements.strong)({});
    (__VLS_ctx.settingsDownloadDir);
    __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
        ...{ onClick: (__VLS_ctx.copyDownloadPath) },
        ...{ class: "secondary-button" },
    });
    /** @type {[typeof AppIcon, ]} */ ;
    // @ts-ignore
    const __VLS_51 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
        name: "copy",
        size: (16),
    }));
    const __VLS_52 = __VLS_51({
        name: "copy",
        size: (16),
    }, ...__VLS_functionalComponentArgsRest(__VLS_51));
    if (__VLS_ctx.historyActionError) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({
            ...{ class: "history-action-error" },
        });
        (__VLS_ctx.historyActionError);
    }
    if (__VLS_ctx.receivedTransfers.length) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "history-list" },
        });
        for (const [item] of __VLS_getVForSourceType((__VLS_ctx.receivedTransfers))) {
            __VLS_asFunctionalElement(__VLS_intrinsicElements.article, __VLS_intrinsicElements.article)({
                key: (`${item.peerId}:${item.id}`),
                ...{ class: "history-row" },
            });
            __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
                ...{ class: "history-direction received" },
            });
            /** @type {[typeof AppIcon, ]} */ ;
            // @ts-ignore
            const __VLS_54 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
                name: "inbox",
                size: (20),
            }));
            const __VLS_55 = __VLS_54({
                name: "inbox",
                size: (20),
            }, ...__VLS_functionalComponentArgsRest(__VLS_54));
            __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
                ...{ class: "history-main" },
            });
            __VLS_asFunctionalElement(__VLS_intrinsicElements.strong, __VLS_intrinsicElements.strong)({});
            (item.totalFiles);
            __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
            (item.peerName || '已配对设备');
            __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
                ...{ class: "history-size" },
            });
            __VLS_asFunctionalElement(__VLS_intrinsicElements.strong, __VLS_intrinsicElements.strong)({});
            (__VLS_ctx.formatSize(item.totalBytes));
            __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
            (__VLS_ctx.formatDate(item.createdAt));
            __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
                ...{ class: (['status-badge', item.status]) },
            });
            (__VLS_ctx.statusLabel(item.status));
            if (__VLS_ctx.canRevealTransfer(item)) {
                __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
                    ...{ onClick: (...[$event]) => {
                            if (!!(__VLS_ctx.activePage === 'home'))
                                return;
                            if (!!(__VLS_ctx.activePage === 'history'))
                                return;
                            if (!(__VLS_ctx.activePage === 'received'))
                                return;
                            if (!(__VLS_ctx.receivedTransfers.length))
                                return;
                            if (!(__VLS_ctx.canRevealTransfer(item)))
                                return;
                            __VLS_ctx.revealTransfer(item);
                        } },
                    ...{ class: "history-action-button" },
                    title: "在资源管理器中显示",
                });
                /** @type {[typeof AppIcon, ]} */ ;
                // @ts-ignore
                const __VLS_57 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
                    name: "folder",
                    size: (15),
                }));
                const __VLS_58 = __VLS_57({
                    name: "folder",
                    size: (15),
                }, ...__VLS_functionalComponentArgsRest(__VLS_57));
            }
        }
    }
    else {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "empty-state page-empty" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "empty-icon" },
        });
        /** @type {[typeof AppIcon, ]} */ ;
        // @ts-ignore
        const __VLS_60 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
            name: "inbox",
            size: (30),
        }));
        const __VLS_61 = __VLS_60({
            name: "inbox",
            size: (30),
        }, ...__VLS_functionalComponentArgsRest(__VLS_60));
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({});
        __VLS_asFunctionalElement(__VLS_intrinsicElements.h3, __VLS_intrinsicElements.h3)({});
        __VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({});
    }
}
else {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.section, __VLS_intrinsicElements.section)({
        ...{ class: "page settings-page" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "settings-column" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.section, __VLS_intrinsicElements.section)({
        ...{ class: "settings-card" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "settings-card-heading" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "setting-icon" },
    });
    /** @type {[typeof AppIcon, ]} */ ;
    // @ts-ignore
    const __VLS_63 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
        name: "computer",
        size: (20),
    }));
    const __VLS_64 = __VLS_63({
        name: "computer",
        size: (20),
    }, ...__VLS_functionalComponentArgsRest(__VLS_63));
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.h2, __VLS_intrinsicElements.h2)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.label, __VLS_intrinsicElements.label)({
        ...{ class: "field" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.input)({
        maxlength: "40",
    });
    (__VLS_ctx.settingsDeviceName);
    __VLS_asFunctionalElement(__VLS_intrinsicElements.section, __VLS_intrinsicElements.section)({
        ...{ class: "settings-card" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "settings-card-heading" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "setting-icon" },
    });
    /** @type {[typeof AppIcon, ]} */ ;
    // @ts-ignore
    const __VLS_66 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
        name: "inbox",
        size: (20),
    }));
    const __VLS_67 = __VLS_66({
        name: "inbox",
        size: (20),
    }, ...__VLS_functionalComponentArgsRest(__VLS_66));
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.h2, __VLS_intrinsicElements.h2)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.label, __VLS_intrinsicElements.label)({
        ...{ class: "field" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "input-action" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.input)({});
    (__VLS_ctx.settingsDownloadDir);
    __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
        ...{ onClick: (__VLS_ctx.copyDownloadPath) },
        ...{ class: "icon-button" },
        title: "复制目录",
    });
    /** @type {[typeof AppIcon, ]} */ ;
    // @ts-ignore
    const __VLS_69 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
        name: "copy",
        size: (17),
    }));
    const __VLS_70 = __VLS_69({
        name: "copy",
        size: (17),
    }, ...__VLS_functionalComponentArgsRest(__VLS_69));
    __VLS_asFunctionalElement(__VLS_intrinsicElements.label, __VLS_intrinsicElements.label)({
        ...{ class: "field" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.select, __VLS_intrinsicElements.select)({
        value: (__VLS_ctx.settingsConflictPolicy),
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.option, __VLS_intrinsicElements.option)({
        value: "rename",
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.option, __VLS_intrinsicElements.option)({
        value: "overwrite",
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.option, __VLS_intrinsicElements.option)({
        value: "skip",
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.label, __VLS_intrinsicElements.label)({
        ...{ class: "toggle-row" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.strong, __VLS_intrinsicElements.strong)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.input)({
        type: "checkbox",
        role: "switch",
    });
    (__VLS_ctx.settingsRequireReceiveConfirmation);
    __VLS_asFunctionalElement(__VLS_intrinsicElements.section, __VLS_intrinsicElements.section)({
        ...{ class: "settings-card" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "settings-card-heading" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "setting-icon" },
    });
    /** @type {[typeof AppIcon, ]} */ ;
    // @ts-ignore
    const __VLS_72 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
        name: "wifi",
        size: (20),
    }));
    const __VLS_73 = __VLS_72({
        name: "wifi",
        size: (20),
    }, ...__VLS_functionalComponentArgsRest(__VLS_72));
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.h2, __VLS_intrinsicElements.h2)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.label, __VLS_intrinsicElements.label)({
        ...{ class: "toggle-row" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.strong, __VLS_intrinsicElements.strong)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.input)({
        type: "checkbox",
        role: "switch",
    });
    (__VLS_ctx.settingsMdnsEnabled);
    __VLS_asFunctionalElement(__VLS_intrinsicElements.label, __VLS_intrinsicElements.label)({
        ...{ class: "toggle-row" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.strong, __VLS_intrinsicElements.strong)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.input)({
        type: "checkbox",
        role: "switch",
    });
    (__VLS_ctx.settingsRequirePairConfirmation);
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "setting-detail" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.strong, __VLS_intrinsicElements.strong)({});
    (__VLS_ctx.settingsNetworkName || '局域网');
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "setting-detail" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.code, __VLS_intrinsicElements.code)({});
    (__VLS_ctx.settingsLocalAddresses.join(' / ') || '未检测到局域网地址');
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "setting-detail" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.code, __VLS_intrinsicElements.code)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "settings-actions" },
    });
    if (__VLS_ctx.settingsError) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
            ...{ class: "error-text" },
        });
        (__VLS_ctx.settingsError);
    }
    else if (__VLS_ctx.settingsSaved) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
            ...{ class: "success-text" },
        });
    }
    __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
        ...{ onClick: (__VLS_ctx.saveSettings) },
        ...{ class: "primary-button" },
        disabled: (__VLS_ctx.settingsSaving),
    });
    (__VLS_ctx.settingsSaving ? '保存中…' : '保存设置');
}
const __VLS_75 = {}.Teleport;
/** @type {[typeof __VLS_components.Teleport, typeof __VLS_components.Teleport, ]} */ ;
// @ts-ignore
const __VLS_76 = __VLS_asFunctionalComponent(__VLS_75, new __VLS_75({
    to: "body",
}));
const __VLS_77 = __VLS_76({
    to: "body",
}, ...__VLS_functionalComponentArgsRest(__VLS_76));
__VLS_78.slots.default;
if (__VLS_ctx.showConnectPanel) {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ onClick: (...[$event]) => {
                if (!(__VLS_ctx.showConnectPanel))
                    return;
                __VLS_ctx.showConnectPanel = false;
            } },
        ...{ class: "modal-overlay" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.section, __VLS_intrinsicElements.section)({
        ...{ class: "modal-card connect-modal" },
        role: "dialog",
        'aria-modal': "true",
        'aria-label': "添加设备",
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "modal-heading" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
        ...{ class: "eyebrow" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.h2, __VLS_intrinsicElements.h2)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
        ...{ onClick: (...[$event]) => {
                if (!(__VLS_ctx.showConnectPanel))
                    return;
                __VLS_ctx.showConnectPanel = false;
            } },
        ...{ class: "icon-button" },
    });
    /** @type {[typeof AppIcon, ]} */ ;
    // @ts-ignore
    const __VLS_79 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
        name: "x",
        size: (19),
    }));
    const __VLS_80 = __VLS_79({
        name: "x",
        size: (19),
    }, ...__VLS_functionalComponentArgsRest(__VLS_79));
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "connect-grid" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "qr-panel" },
    });
    if (__VLS_ctx.qrLoading && !__VLS_ctx.qrDataUrl) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "qr-placeholder" },
        });
    }
    else if (__VLS_ctx.qrDataUrl) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.img)({
            src: (__VLS_ctx.qrDataUrl),
            alt: "FastDrop 配对二维码",
        });
    }
    else {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "qr-placeholder error-text" },
        });
        (__VLS_ctx.qrError);
    }
    __VLS_asFunctionalElement(__VLS_intrinsicElements.strong, __VLS_intrinsicElements.strong)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
    (__VLS_ctx.countdown);
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "manual-panel" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "manual-icon" },
    });
    /** @type {[typeof AppIcon, ]} */ ;
    // @ts-ignore
    const __VLS_82 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
        name: "wifi",
        size: (24),
    }));
    const __VLS_83 = __VLS_82({
        name: "wifi",
        size: (24),
    }, ...__VLS_functionalComponentArgsRest(__VLS_82));
    __VLS_asFunctionalElement(__VLS_intrinsicElements.h3, __VLS_intrinsicElements.h3)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.input)({
        ...{ onKeyup: (__VLS_ctx.connectRemotePeer) },
        placeholder: "192.168.1.23:9527",
    });
    (__VLS_ctx.remoteAddress);
    __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
        ...{ onClick: (__VLS_ctx.connectRemotePeer) },
        ...{ class: "primary-button full" },
        disabled: (__VLS_ctx.remotePairing),
    });
    (__VLS_ctx.remotePairing ? '连接中…' : '连接设备');
    if (__VLS_ctx.remotePairStatus) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
            ...{ class: "inline-notice" },
        });
        (__VLS_ctx.remotePairStatus);
    }
}
if (__VLS_ctx.showPairDialog && __VLS_ctx.pendingRequests.length) {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "modal-overlay" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.section, __VLS_intrinsicElements.section)({
        ...{ class: "modal-card" },
        role: "dialog",
        'aria-modal': "true",
        'aria-label': "配对请求",
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "modal-heading" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
        ...{ class: "eyebrow" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.h2, __VLS_intrinsicElements.h2)({});
    for (const [request] of __VLS_getVForSourceType((__VLS_ctx.pendingRequests))) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.article, __VLS_intrinsicElements.article)({
            key: (request.requestId),
            ...{ class: "request-row" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "device-avatar" },
        });
        /** @type {[typeof AppIcon, ]} */ ;
        // @ts-ignore
        const __VLS_85 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
            name: (request.platform === 'windows' ? 'computer' : 'phone'),
            size: (25),
        }));
        const __VLS_86 = __VLS_85({
            name: (request.platform === 'windows' ? 'computer' : 'phone'),
            size: (25),
        }, ...__VLS_functionalComponentArgsRest(__VLS_85));
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({});
        __VLS_asFunctionalElement(__VLS_intrinsicElements.strong, __VLS_intrinsicElements.strong)({});
        (request.deviceName);
        __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
        (request.platform);
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "request-actions" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
            ...{ onClick: (...[$event]) => {
                    if (!(__VLS_ctx.showPairDialog && __VLS_ctx.pendingRequests.length))
                        return;
                    __VLS_ctx.handleReject(request.requestId);
                } },
            ...{ class: "tertiary-button danger-text" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
            ...{ onClick: (...[$event]) => {
                    if (!(__VLS_ctx.showPairDialog && __VLS_ctx.pendingRequests.length))
                        return;
                    __VLS_ctx.handleAccept(request);
                } },
            ...{ class: "primary-button" },
        });
    }
}
if (__VLS_ctx.incomingOffers.length) {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "modal-overlay" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.section, __VLS_intrinsicElements.section)({
        ...{ class: "modal-card" },
        role: "dialog",
        'aria-modal': "true",
        'aria-label': "接收文件",
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "modal-heading" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
        ...{ class: "eyebrow" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.h2, __VLS_intrinsicElements.h2)({});
    (__VLS_ctx.incomingOffers[0].deviceName);
    __VLS_asFunctionalElement(__VLS_intrinsicElements.ul, __VLS_intrinsicElements.ul)({
        ...{ class: "offer-list" },
    });
    for (const [file] of __VLS_getVForSourceType((__VLS_ctx.incomingOffers[0].files))) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.li, __VLS_intrinsicElements.li)({
            key: (file.fileId),
        });
        /** @type {[typeof AppIcon, ]} */ ;
        // @ts-ignore
        const __VLS_88 = __VLS_asFunctionalComponent(AppIcon, new AppIcon({
            name: "file",
            size: (18),
        }));
        const __VLS_89 = __VLS_88({
            name: "file",
            size: (18),
        }, ...__VLS_functionalComponentArgsRest(__VLS_88));
        __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
        (file.name);
        __VLS_asFunctionalElement(__VLS_intrinsicElements.small, __VLS_intrinsicElements.small)({});
        (__VLS_ctx.formatSize(file.size));
    }
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "modal-actions" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
        ...{ onClick: (...[$event]) => {
                if (!(__VLS_ctx.incomingOffers.length))
                    return;
                __VLS_ctx.rejectOffer(__VLS_ctx.incomingOffers[0]);
            } },
        ...{ class: "secondary-button" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
        ...{ onClick: (...[$event]) => {
                if (!(__VLS_ctx.incomingOffers.length))
                    return;
                __VLS_ctx.acceptOffer(__VLS_ctx.incomingOffers[0]);
            } },
        ...{ class: "primary-button" },
    });
}
var __VLS_78;
/** @type {__VLS_StyleScopedClasses['desktop-shell']} */ ;
/** @type {__VLS_StyleScopedClasses['sidebar']} */ ;
/** @type {__VLS_StyleScopedClasses['brand']} */ ;
/** @type {__VLS_StyleScopedClasses['brand-mark']} */ ;
/** @type {__VLS_StyleScopedClasses['side-nav']} */ ;
/** @type {__VLS_StyleScopedClasses['nav-count']} */ ;
/** @type {__VLS_StyleScopedClasses['sidebar-status']} */ ;
/** @type {__VLS_StyleScopedClasses['service-line']} */ ;
/** @type {__VLS_StyleScopedClasses['version-line']} */ ;
/** @type {__VLS_StyleScopedClasses['workspace']} */ ;
/** @type {__VLS_StyleScopedClasses['topbar']} */ ;
/** @type {__VLS_StyleScopedClasses['eyebrow']} */ ;
/** @type {__VLS_StyleScopedClasses['topbar-actions']} */ ;
/** @type {__VLS_StyleScopedClasses['online-pill']} */ ;
/** @type {__VLS_StyleScopedClasses['status-dot']} */ ;
/** @type {__VLS_StyleScopedClasses['online']} */ ;
/** @type {__VLS_StyleScopedClasses['icon-button']} */ ;
/** @type {__VLS_StyleScopedClasses['page']} */ ;
/** @type {__VLS_StyleScopedClasses['home-page']} */ ;
/** @type {__VLS_StyleScopedClasses['drop-icon']} */ ;
/** @type {__VLS_StyleScopedClasses['drop-copy']} */ ;
/** @type {__VLS_StyleScopedClasses['drop-actions']} */ ;
/** @type {__VLS_StyleScopedClasses['primary-button']} */ ;
/** @type {__VLS_StyleScopedClasses['secondary-button']} */ ;
/** @type {__VLS_StyleScopedClasses['inline-notice']} */ ;
/** @type {__VLS_StyleScopedClasses['section-heading']} */ ;
/** @type {__VLS_StyleScopedClasses['text-button']} */ ;
/** @type {__VLS_StyleScopedClasses['device-grid']} */ ;
/** @type {__VLS_StyleScopedClasses['device-avatar']} */ ;
/** @type {__VLS_StyleScopedClasses['device-copy']} */ ;
/** @type {__VLS_StyleScopedClasses['device-check']} */ ;
/** @type {__VLS_StyleScopedClasses['empty-state']} */ ;
/** @type {__VLS_StyleScopedClasses['compact']} */ ;
/** @type {__VLS_StyleScopedClasses['empty-icon']} */ ;
/** @type {__VLS_StyleScopedClasses['primary-button']} */ ;
/** @type {__VLS_StyleScopedClasses['selection-summary']} */ ;
/** @type {__VLS_StyleScopedClasses['transfer-drawer']} */ ;
/** @type {__VLS_StyleScopedClasses['drawer-heading']} */ ;
/** @type {__VLS_StyleScopedClasses['status-dot']} */ ;
/** @type {__VLS_StyleScopedClasses['online']} */ ;
/** @type {__VLS_StyleScopedClasses['text-button']} */ ;
/** @type {__VLS_StyleScopedClasses['transfer-row']} */ ;
/** @type {__VLS_StyleScopedClasses['file-avatar']} */ ;
/** @type {__VLS_StyleScopedClasses['transfer-main']} */ ;
/** @type {__VLS_StyleScopedClasses['transfer-title']} */ ;
/** @type {__VLS_StyleScopedClasses['progress-track']} */ ;
/** @type {__VLS_StyleScopedClasses['transfer-meta']} */ ;
/** @type {__VLS_StyleScopedClasses['row-actions']} */ ;
/** @type {__VLS_StyleScopedClasses['icon-button']} */ ;
/** @type {__VLS_StyleScopedClasses['icon-button']} */ ;
/** @type {__VLS_StyleScopedClasses['icon-button']} */ ;
/** @type {__VLS_StyleScopedClasses['danger']} */ ;
/** @type {__VLS_StyleScopedClasses['page']} */ ;
/** @type {__VLS_StyleScopedClasses['toolbar']} */ ;
/** @type {__VLS_StyleScopedClasses['segmented-control']} */ ;
/** @type {__VLS_StyleScopedClasses['search-input']} */ ;
/** @type {__VLS_StyleScopedClasses['history-action-error']} */ ;
/** @type {__VLS_StyleScopedClasses['loading-state']} */ ;
/** @type {__VLS_StyleScopedClasses['history-list']} */ ;
/** @type {__VLS_StyleScopedClasses['history-row']} */ ;
/** @type {__VLS_StyleScopedClasses['history-main']} */ ;
/** @type {__VLS_StyleScopedClasses['history-size']} */ ;
/** @type {__VLS_StyleScopedClasses['history-action-button']} */ ;
/** @type {__VLS_StyleScopedClasses['empty-state']} */ ;
/** @type {__VLS_StyleScopedClasses['page-empty']} */ ;
/** @type {__VLS_StyleScopedClasses['empty-icon']} */ ;
/** @type {__VLS_StyleScopedClasses['primary-button']} */ ;
/** @type {__VLS_StyleScopedClasses['page']} */ ;
/** @type {__VLS_StyleScopedClasses['received-hero']} */ ;
/** @type {__VLS_StyleScopedClasses['received-icon']} */ ;
/** @type {__VLS_StyleScopedClasses['secondary-button']} */ ;
/** @type {__VLS_StyleScopedClasses['history-action-error']} */ ;
/** @type {__VLS_StyleScopedClasses['history-list']} */ ;
/** @type {__VLS_StyleScopedClasses['history-row']} */ ;
/** @type {__VLS_StyleScopedClasses['history-direction']} */ ;
/** @type {__VLS_StyleScopedClasses['received']} */ ;
/** @type {__VLS_StyleScopedClasses['history-main']} */ ;
/** @type {__VLS_StyleScopedClasses['history-size']} */ ;
/** @type {__VLS_StyleScopedClasses['history-action-button']} */ ;
/** @type {__VLS_StyleScopedClasses['empty-state']} */ ;
/** @type {__VLS_StyleScopedClasses['page-empty']} */ ;
/** @type {__VLS_StyleScopedClasses['empty-icon']} */ ;
/** @type {__VLS_StyleScopedClasses['page']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-page']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-column']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-card']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-card-heading']} */ ;
/** @type {__VLS_StyleScopedClasses['setting-icon']} */ ;
/** @type {__VLS_StyleScopedClasses['field']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-card']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-card-heading']} */ ;
/** @type {__VLS_StyleScopedClasses['setting-icon']} */ ;
/** @type {__VLS_StyleScopedClasses['field']} */ ;
/** @type {__VLS_StyleScopedClasses['input-action']} */ ;
/** @type {__VLS_StyleScopedClasses['icon-button']} */ ;
/** @type {__VLS_StyleScopedClasses['field']} */ ;
/** @type {__VLS_StyleScopedClasses['toggle-row']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-card']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-card-heading']} */ ;
/** @type {__VLS_StyleScopedClasses['setting-icon']} */ ;
/** @type {__VLS_StyleScopedClasses['toggle-row']} */ ;
/** @type {__VLS_StyleScopedClasses['toggle-row']} */ ;
/** @type {__VLS_StyleScopedClasses['setting-detail']} */ ;
/** @type {__VLS_StyleScopedClasses['setting-detail']} */ ;
/** @type {__VLS_StyleScopedClasses['setting-detail']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-actions']} */ ;
/** @type {__VLS_StyleScopedClasses['error-text']} */ ;
/** @type {__VLS_StyleScopedClasses['success-text']} */ ;
/** @type {__VLS_StyleScopedClasses['primary-button']} */ ;
/** @type {__VLS_StyleScopedClasses['modal-overlay']} */ ;
/** @type {__VLS_StyleScopedClasses['modal-card']} */ ;
/** @type {__VLS_StyleScopedClasses['connect-modal']} */ ;
/** @type {__VLS_StyleScopedClasses['modal-heading']} */ ;
/** @type {__VLS_StyleScopedClasses['eyebrow']} */ ;
/** @type {__VLS_StyleScopedClasses['icon-button']} */ ;
/** @type {__VLS_StyleScopedClasses['connect-grid']} */ ;
/** @type {__VLS_StyleScopedClasses['qr-panel']} */ ;
/** @type {__VLS_StyleScopedClasses['qr-placeholder']} */ ;
/** @type {__VLS_StyleScopedClasses['qr-placeholder']} */ ;
/** @type {__VLS_StyleScopedClasses['error-text']} */ ;
/** @type {__VLS_StyleScopedClasses['manual-panel']} */ ;
/** @type {__VLS_StyleScopedClasses['manual-icon']} */ ;
/** @type {__VLS_StyleScopedClasses['primary-button']} */ ;
/** @type {__VLS_StyleScopedClasses['full']} */ ;
/** @type {__VLS_StyleScopedClasses['inline-notice']} */ ;
/** @type {__VLS_StyleScopedClasses['modal-overlay']} */ ;
/** @type {__VLS_StyleScopedClasses['modal-card']} */ ;
/** @type {__VLS_StyleScopedClasses['modal-heading']} */ ;
/** @type {__VLS_StyleScopedClasses['eyebrow']} */ ;
/** @type {__VLS_StyleScopedClasses['request-row']} */ ;
/** @type {__VLS_StyleScopedClasses['device-avatar']} */ ;
/** @type {__VLS_StyleScopedClasses['request-actions']} */ ;
/** @type {__VLS_StyleScopedClasses['tertiary-button']} */ ;
/** @type {__VLS_StyleScopedClasses['danger-text']} */ ;
/** @type {__VLS_StyleScopedClasses['primary-button']} */ ;
/** @type {__VLS_StyleScopedClasses['modal-overlay']} */ ;
/** @type {__VLS_StyleScopedClasses['modal-card']} */ ;
/** @type {__VLS_StyleScopedClasses['modal-heading']} */ ;
/** @type {__VLS_StyleScopedClasses['eyebrow']} */ ;
/** @type {__VLS_StyleScopedClasses['offer-list']} */ ;
/** @type {__VLS_StyleScopedClasses['modal-actions']} */ ;
/** @type {__VLS_StyleScopedClasses['secondary-button']} */ ;
/** @type {__VLS_StyleScopedClasses['primary-button']} */ ;
var __VLS_dollars;
const __VLS_self = (await import('vue')).defineComponent({
    setup() {
        return {
            AppIcon: AppIcon,
            activePage: activePage,
            dragOver: dragOver,
            uploadStatus: uploadStatus,
            fileInput: fileInput,
            folderInput: folderInput,
            activeTransfers: activeTransfers,
            incomingOffers: incomingOffers,
            historyLoading: historyLoading,
            historyFilter: historyFilter,
            historySearch: historySearch,
            historyActionError: historyActionError,
            pendingRequests: pendingRequests,
            showPairDialog: showPairDialog,
            showConnectPanel: showConnectPanel,
            remoteAddress: remoteAddress,
            remotePairStatus: remotePairStatus,
            remotePairing: remotePairing,
            qrDataUrl: qrDataUrl,
            qrLoading: qrLoading,
            qrError: qrError,
            countdown: countdown,
            serverName: serverName,
            settingsDeviceName: settingsDeviceName,
            settingsDownloadDir: settingsDownloadDir,
            settingsConflictPolicy: settingsConflictPolicy,
            settingsMdnsEnabled: settingsMdnsEnabled,
            settingsRequirePairConfirmation: settingsRequirePairConfirmation,
            settingsRequireReceiveConfirmation: settingsRequireReceiveConfirmation,
            settingsNetworkName: settingsNetworkName,
            settingsLocalAddresses: settingsLocalAddresses,
            settingsSaving: settingsSaving,
            settingsSaved: settingsSaved,
            settingsError: settingsError,
            peerViews: peerViews,
            selectedRecipientIds: selectedRecipientIds,
            connectedPeers: connectedPeers,
            selectedCount: selectedCount,
            liveTransfers: liveTransfers,
            completedTransfers: completedTransfers,
            receivedTransfers: receivedTransfers,
            displayedHistory: displayedHistory,
            serviceAddress: serviceAddress,
            serviceOnline: serviceOnline,
            desktopNetworkLabel: desktopNetworkLabel,
            desktopNetworkTitle: desktopNetworkTitle,
            navItems: navItems,
            selectPage: selectPage,
            openFilePicker: openFilePicker,
            openFolderPicker: openFolderPicker,
            handleFilePickerChange: handleFilePickerChange,
            handleDragOver: handleDragOver,
            handleDragLeave: handleDragLeave,
            handleDrop: handleDrop,
            toggleRecipient: toggleRecipient,
            pauseTransfer: pauseTransfer,
            resumeTransfer: resumeTransfer,
            cancelTransfer: cancelTransfer,
            acceptOffer: acceptOffer,
            rejectOffer: rejectOffer,
            handleAccept: handleAccept,
            handleReject: handleReject,
            connectRemotePeer: connectRemotePeer,
            canRevealTransfer: canRevealTransfer,
            revealTransfer: revealTransfer,
            saveSettings: saveSettings,
            copyDownloadPath: copyDownloadPath,
            refreshDesktopState: refreshDesktopState,
            isTerminal: isTerminal,
            progressPercent: progressPercent,
            formatSize: formatSize,
            formatSpeed: formatSpeed,
            formatDate: formatDate,
            statusLabel: statusLabel,
        };
    },
});
export default (await import('vue')).defineComponent({
    setup() {
        return {};
    },
});
; /* PartiallyEnd: #4569/main.vue */
