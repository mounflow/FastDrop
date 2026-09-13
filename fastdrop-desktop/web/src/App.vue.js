import { computed, onMounted, onUnmounted, ref } from 'vue';
import QRCode from 'qrcode';
import { acceptPair, createTransfer, fetchQR, getSettings, getServerInfo, getTransfer, listPairRequests, listTransfers, pollPairStatus, rejectPair, requestDiscoverPair, restoreSession, setSession, updateSettings, uploadChunk, } from './api';
import { useWebSocket } from './composables/useWebSocket';
import { usePeerPool, } from './composables/usePeerPool';
const peerPool = usePeerPool({
    onMessage: (peerId, message) => handleWSMessage(message, peerId),
    onProgress: (progress) => handlePoolProgress(progress),
    onPeerChanged: () => {
        isPaired.value = peerPool.peers.value.length > 0;
        const connected = peerPool.peers.value.filter((peer) => peer.status === 'connected');
        phoneConnected.value = connected.length > 0;
        phoneName.value = connected.length === 1
            ? connected[0].name
            : `${connected.length} 台设备`;
        wsStatus.value = connected.length > 0
            ? 'connected'
            : peerPool.peers.value.some((peer) => peer.status === 'reconnecting')
                ? 'reconnecting'
                : peerPool.peers.value.some((peer) => peer.status === 'connecting')
                    ? 'connecting'
                    : 'disconnected';
    },
    onAuthFailed: (peerId) => {
        incomingOffers.value = incomingOffers.value.filter((offer) => offer.peerId !== peerId);
    },
});
const peerViews = peerPool.peers;
const selectedRecipientIds = peerPool.selectedIds;
const connectedPeerCount = computed(() => peerViews.value.filter((peer) => peer.status === 'connected').length);
// ========== QR code / server info ==========
const qrDataUrl = ref('');
const qrPayload = ref(null);
const countdown = ref(0);
const serverName = ref('FastDrop-PC');
const qrLoading = ref(false);
const qrError = ref(null);
let qrTimer = null;
let countdownTimer = null;
async function refreshQR() {
    qrLoading.value = true;
    qrError.value = null;
    try {
        const payload = await fetchQR();
        qrPayload.value = payload;
        serverName.value = payload.serverName;
        countdown.value = Math.max(0, payload.expiresAt - Math.floor(Date.now() / 1000));
        qrDataUrl.value = await QRCode.toDataURL(JSON.stringify(payload), { width: 256 });
    }
    catch (e) {
        qrError.value = 'Failed to load QR code';
        console.error(e);
    }
    finally {
        qrLoading.value = false;
    }
}
function tickCountdown() {
    if (countdown.value > 0)
        countdown.value--;
    if (countdown.value === 0)
        refreshQR();
}
// ========== Drag-and-drop + file picker upload ==========
const dragOver = ref(false);
const uploadStatus = ref('');
const fileInput = ref(null);
async function handleDragOver(e) {
    e.preventDefault();
    dragOver.value = true;
}
function handleDragLeave() {
    dragOver.value = false;
}
async function handleDrop(e) {
    e.preventDefault();
    dragOver.value = false;
    const files = Array.from(e.dataTransfer?.files || []);
    if (files.length === 0)
        return;
    await sendFiles(files);
}
function openFilePicker() {
    fileInput.value?.click();
}
async function handleFilePickerChange(e) {
    const input = e.target;
    const files = Array.from(input.files || []);
    input.value = ''; // reset so the same file can be re-selected
    if (files.length === 0)
        return;
    await sendFiles(files);
}
async function sendFiles(files) {
    if (selectedRecipientIds.value.length === 0) {
        uploadStatus.value = '请至少选择一个在线接收设备。';
        return;
    }
    uploadStatus.value = `Preparing ${files.length} file(s)...`;
    try {
        await peerPool.sendFiles(files, selectedRecipientIds.value);
        uploadStatus.value = `已向 ${selectedRecipientIds.value.length} 台设备发起发送`;
        await loadHistory();
    }
    catch (e) {
        uploadStatus.value = `Failed: ${e.message}`;
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
async function stageAndOfferFile(file) {
    const offerId = crypto.randomUUID();
    const createBody = {
        offerId,
        direction: 'server_to_client',
        files: [
            {
                clientFileId: file.name,
                name: file.name,
                size: file.size,
                mimeType: file.type || 'application/octet-stream',
            },
        ],
    };
    const res = await createTransfer(createBody);
    const f = res.files[0];
    const chunkSize = f.chunkSize;
    for (let i = 0; i < f.totalChunks; i++) {
        const start = i * chunkSize;
        const end = Math.min(start + chunkSize, file.size);
        const buf = await file.slice(start, end).arrayBuffer();
        const url = `/api/v1/transfers/${res.transferId}/files/${f.fileId}/chunks/${i}`;
        await uploadChunk(url, buf);
        uploadStatus.value = `${file.name}: staged ${i + 1}/${f.totalChunks} chunks`;
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
    });
    uploadStatus.value = `${file.name} offered to phone`;
}
const pendingRequests = ref([]);
const showPairDialog = ref(false);
const isPaired = ref(false);
let pairPollTimer = null;
const remoteAddress = ref('');
const remotePairStatus = ref('');
const remotePairing = ref(false);
async function connectRemotePeer() {
    if (remotePairing.value)
        return;
    const input = remoteAddress.value.trim();
    if (!input)
        return;
    remotePairing.value = true;
    remotePairStatus.value = '正在请求对方确认…';
    try {
        const baseUrl = normalizePeerUrl(input);
        const remote = await getServerInfo(baseUrl);
        const localClientId = getLocalClientId();
        const request = await requestDiscoverPair(baseUrl, {
            deviceId: localClientId,
            deviceName: serverName.value || location.hostname,
            platform: 'windows',
            appVersion: '1.0.0',
        });
        const deadline = Date.now() + 30_000;
        while (Date.now() < deadline) {
            await new Promise((resolve) => setTimeout(resolve, 1_000));
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
                remotePairStatus.value = `已连接 ${accepted.server.deviceName}`;
                remoteAddress.value = '';
                isPaired.value = true;
                return;
            }
            if (result.status === 'rejected' || result.status === 'expired') {
                throw new Error(result.status === 'rejected' ? '对方已拒绝' : '配对请求已过期');
            }
        }
        throw new Error('等待确认超时');
    }
    catch (error) {
        remotePairStatus.value = `连接失败：${error.message}`;
    }
    finally {
        remotePairing.value = false;
    }
}
function normalizePeerUrl(input) {
    const withScheme = /^https?:\/\//i.test(input) ? input : `http://${input}`;
    const url = new URL(withScheme);
    if (!url.port)
        url.port = '9527';
    return url.origin;
}
function getLocalClientId() {
    const key = 'fastdrop_pc_client_id';
    const existing = localStorage.getItem(key);
    if (existing)
        return existing;
    const id = crypto.randomUUID();
    localStorage.setItem(key, id);
    return id;
}
async function pollPairRequests() {
    try {
        const res = await listPairRequests();
        const waiting = (res.requests || []).filter((r) => r.status === 'waiting_confirmation');
        if (waiting.length > 0) {
            pendingRequests.value = waiting;
            showPairDialog.value = true;
        }
    }
    catch {
        // endpoint may not be available yet; silently retry
    }
}
async function handleAccept(requestId) {
    try {
        const res = await acceptPair(requestId);
        const request = pendingRequests.value.find((item) => item.requestId === requestId);
        peerPool.addPeer({
            id: `${request?.deviceId ?? requestId}::${res.session.sessionId}`,
            name: request?.deviceName ?? 'Device',
            platform: request?.platform ?? 'unknown',
            baseUrl: location.origin,
            sessionId: res.session.sessionId,
            accessToken: res.session.accessToken,
            websocketUrl: res.session.websocketUrl,
            role: 'local-session',
        });
        pendingRequests.value = pendingRequests.value.filter((item) => item.requestId !== requestId);
        showPairDialog.value = pendingRequests.value.length > 0;
        isPaired.value = true;
    }
    catch (e) {
        console.error('Accept failed:', e);
    }
}
async function handleReject(requestId) {
    try {
        await rejectPair(requestId);
        showPairDialog.value = false;
        pendingRequests.value = pendingRequests.value.filter((r) => r.requestId !== requestId);
    }
    catch (e) {
        console.error('Reject failed:', e);
    }
}
/// User clicked "重新配对" — revoke the current session so the server
/// broadcasts session.revoked, which our WS handler already turns
/// into the QR pairing view. No local state reset needed here; the
/// revoked handler does it all.
async function handleReconnect() {
    if (!confirm('确定要移除全部已配对设备吗？'))
        return;
    for (const peer of [...peerViews.value])
        peerPool.removePeer(peer.id);
    setSession(null);
    isPaired.value = false;
    activeTransfers.value = [];
    incomingOffers.value = [];
    refreshQR();
}
// ========== WebSocket ==========
const wsStatus = ref('disconnected');
const phoneConnected = ref(false);
const phoneName = ref('');
let wsClient = null;
const incomingOffers = ref([]);
const activeTransfers = ref([]);
function handlePoolProgress(progress) {
    const existing = activeTransfers.value.find((item) => item.peerId === progress.peerId
        && item.transferId === progress.transferId
        && item.fileId === progress.fileId);
    if (existing) {
        existing.transferredBytes = progress.transferredBytes;
        existing.status = progress.status;
        existing.error = progress.error;
    }
    else {
        activeTransfers.value.push({
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
}
function pauseTransfer(transferId) {
    const t = activeTransfers.value.find((t) => t.transferId === transferId);
    if (t)
        t.status = 'paused';
    if (!t)
        return;
    peerPool.send(t.peerId, {
        version: 1,
        type: 'transfer.pause',
        messageId: crypto.randomUUID(),
        timestamp: Date.now(),
        payload: { transferId },
    });
}
function resumeTransfer(transferId) {
    const t = activeTransfers.value.find((t) => t.transferId === transferId);
    if (t)
        t.status = 'transferring';
    if (!t)
        return;
    peerPool.send(t.peerId, {
        version: 1,
        type: 'transfer.resume',
        messageId: crypto.randomUUID(),
        timestamp: Date.now(),
        payload: { transferId },
    });
}
function retryTransfer(transferId) {
    // Remove from active list; user re-selects files to retry.
    activeTransfers.value = activeTransfers.value.filter((t) => t.transferId !== transferId);
}
function connectWS(sessionId, accessToken, wsUrl) {
    wsClient = useWebSocket({
        url: wsUrl,
        sessionId,
        accessToken,
        handlers: {
            onOpen: () => { wsStatus.value = 'connected'; },
            onMessage: handleWSMessage,
            onClose: () => {
                if (wsStatus.value !== 'disconnected') {
                    wsStatus.value = 'reconnecting';
                }
            },
            onError: () => { },
            onAuthFailed: () => {
                // Session revoked (e.g. server restarted) — reset to pairing.
                setSession(null); // clear sessionStorage too
                isPaired.value = false;
                wsStatus.value = 'disconnected';
                phoneConnected.value = false;
                phoneName.value = '';
                activeTransfers.value = [];
                incomingOffers.value = [];
                wsClient = null;
                refreshQR();
                // Restart QR polling if it wasn't running (e.g. after restore).
                if (!qrTimer)
                    qrTimer = setInterval(refreshQR, 50_000);
                if (!countdownTimer)
                    countdownTimer = setInterval(tickCountdown, 1000);
                if (!pairPollTimer)
                    pairPollTimer = setInterval(pollPairRequests, 2000);
            },
        },
    });
    wsStatus.value = 'connecting';
}
function handleWSMessage(raw, peerId = '') {
    const msg = raw;
    if (!msg?.type)
        return;
    const p = (msg.payload ?? {});
    switch (msg.type) {
        case 'file.offer': {
            // The local Go hub broadcasts session events to both the remote peer
            // and this browser. Ignore the browser's own outbound announcement.
            if (activeTransfers.value.some((transfer) => transfer.peerId === peerId
                && transfer.transferId === p.transferId))
                break;
            incomingOffers.value.push({
                peerId,
                transferId: p.transferId,
                offerId: p.offerId || p.transferId,
                deviceName: p.deviceName || peerNameFor(peerId),
                files: p.files || [],
            });
            break;
        }
        case 'transfer.started': {
            const t = activeTransfers.value.find((t) => t.transferId === p.transferId);
            if (t)
                t.status = 'transferring';
            break;
        }
        case 'file.offer.accept':
        case 'transfer.accepted': {
            const t = activeTransfers.value.find((t) => t.peerId === peerId && t.transferId === p.transferId);
            if (t)
                t.status = 'transferring';
            break;
        }
        case 'file.offer.reject':
        case 'transfer.rejected': {
            for (const t of activeTransfers.value.filter((t) => t.peerId === peerId && t.transferId === p.transferId)) {
                t.status = 'failed';
                t.error = 'Recipient rejected the transfer';
            }
            break;
        }
        case 'transfer.progress': {
            const existing = activeTransfers.value.find((t) => t.transferId === p.transferId);
            if (existing) {
                existing.transferredBytes = p.transferredBytes;
                existing.speedBps = p.speedBps || 0;
                existing.status = 'transferring';
            }
            break;
        }
        case 'transfer.verifying': {
            const t = activeTransfers.value.find((t) => t.transferId === p.transferId);
            if (t)
                t.status = 'verifying';
            break;
        }
        case 'transfer.paused': {
            const t = activeTransfers.value.find((t) => t.transferId === p.transferId);
            if (t)
                t.status = 'paused';
            break;
        }
        case 'transfer.resume': {
            const t = activeTransfers.value.find((t) => t.transferId === p.transferId);
            if (t)
                t.status = 'transferring';
            break;
        }
        case 'transfer.completed': {
            let completed = activeTransfers.value.filter((t) => t.transferId === p.transferId);
            // Race condition: transfer may complete before the user clicks
            // Accept, so it's still in incomingOffers. Auto-promote it.
            if (completed.length === 0) {
                const offerIdx = incomingOffers.value.findIndex((o) => o.transferId === p.transferId);
                if (offerIdx >= 0) {
                    const offer = incomingOffers.value[offerIdx];
                    incomingOffers.value.splice(offerIdx, 1);
                    for (const f of offer.files) {
                        activeTransfers.value.push({
                            peerId: offer.peerId,
                            peerName: peerNameFor(offer.peerId),
                            transferId: offer.transferId,
                            fileId: f.fileId,
                            filename: f.name,
                            totalBytes: f.size,
                            transferredBytes: f.size,
                            speedBps: 0,
                            status: 'completed',
                        });
                    }
                    completed = activeTransfers.value.filter((t) => t.transferId === p.transferId);
                }
            }
            for (const t of completed) {
                t.status = 'completed';
                t.transferredBytes = t.totalBytes;
            }
            loadHistory();
            break;
        }
        case 'transfer.failed': {
            const t = activeTransfers.value.find((t) => t.transferId === p.transferId);
            if (t) {
                t.status = 'failed';
                // Go sends error as a plain string, not {message}.
                t.error = typeof p.error === 'string'
                    ? p.error
                    : p.error?.message || 'Transfer failed';
            }
            loadHistory();
            break;
        }
        case 'transfer.cancelled': {
            const idx = activeTransfers.value.findIndex((t) => t.transferId === p.transferId);
            if (idx >= 0)
                activeTransfers.value.splice(idx, 1);
            loadHistory();
            break;
        }
        case 'error': {
            // Server-side error notification.
            const code = p.code || 'UNKNOWN';
            const message = p.message || 'Server error';
            uploadStatus.value = `[${code}] ${message}`;
            break;
        }
        case 'device.info': {
            // Phone connected to this session.
            phoneConnected.value = true;
            phoneName.value = p.deviceName || 'Phone';
            break;
        }
        case 'device.disconnect': {
            // Phone disconnected — update status and mark active transfers.
            phoneConnected.value = false;
            phoneName.value = '';
            for (const t of activeTransfers.value) {
                if (t.status === 'transferring' || t.status === 'paused') {
                    t.status = 'failed';
                    t.error = 'Device disconnected';
                }
            }
            break;
        }
        case 'session.revoked': {
            peerPool.removePeer(peerId);
            activeTransfers.value = activeTransfers.value.filter((transfer) => transfer.peerId !== peerId);
            incomingOffers.value = incomingOffers.value.filter((offer) => offer.peerId !== peerId);
            refreshQR();
            break;
        }
    }
}
async function acceptOffer(offer) {
    incomingOffers.value = incomingOffers.value.filter((o) => o.transferId !== offer.transferId);
    for (const f of offer.files) {
        activeTransfers.value.push({
            peerId: offer.peerId,
            peerName: peerNameFor(offer.peerId),
            transferId: offer.transferId,
            fileId: f.fileId,
            filename: f.name,
            totalBytes: f.size,
            transferredBytes: 0,
            speedBps: 0,
            status: 'transferring',
        });
    }
    await peerPool.acceptOffer(offer);
    // The transfer may have already completed before the user clicked
    // Accept (small files upload in <200 ms). Poll the server once to
    // sync the real status so the UI doesn't stick on "transferring".
    try {
        const peer = peerViews.value.find((item) => item.id === offer.peerId);
        const row = await getTransfer(offer.transferId, peer);
        if (row.status === 'completed' || row.status === 'verifying') {
            for (const t of activeTransfers.value.filter((t) => t.transferId === offer.transferId)) {
                t.status = 'completed';
                t.transferredBytes = t.totalBytes;
            }
            loadHistory();
        }
    }
    catch (_) {
        // Best-effort; WS events will update the status eventually.
    }
}
function rejectOffer(offer) {
    incomingOffers.value = incomingOffers.value.filter((o) => o.transferId !== offer.transferId);
    peerPool.rejectOffer(offer);
}
function cancelTransfer(transferId) {
    const transfer = activeTransfers.value.find((item) => item.transferId === transferId);
    activeTransfers.value = activeTransfers.value.filter((t) => t.transferId !== transferId);
    if (!transfer)
        return;
    peerPool.send(transfer.peerId, {
        version: 1,
        type: 'transfer.cancel',
        messageId: crypto.randomUUID(),
        timestamp: Date.now(),
        payload: { transferId },
    });
}
// ========== Transfer history ==========
const transfers = ref([]);
const historyLoading = ref(false);
async function loadHistory() {
    historyLoading.value = true;
    try {
        transfers.value = await peerPool.loadHistory();
    }
    catch {
        transfers.value = [];
    }
    finally {
        historyLoading.value = false;
    }
}
// ========== Helpers ==========
function formatSize(bytes) {
    if (bytes >= 1_000_000_000)
        return `${(bytes / 1_000_000_000).toFixed(1)} GB`;
    if (bytes >= 1_000_000)
        return `${(bytes / 1_000_000).toFixed(1)} MB`;
    if (bytes >= 1_000)
        return `${(bytes / 1_000).toFixed(0)} KB`;
    return `${bytes} B`;
}
function peerNameFor(peerId) {
    return peerViews.value.find((peer) => peer.id === peerId)?.name || 'Device';
}
function formatSpeed(bps) {
    if (bps <= 0)
        return '';
    return `${formatSize(Math.round(bps))}/s`;
}
function progressPercent(t) {
    if (t.totalBytes <= 0)
        return 0;
    return Math.min(100, Math.round((t.transferredBytes / t.totalBytes) * 100));
}
// ========== Settings ==========
const showSettings = ref(false);
const settingsDownloadDir = ref('');
const settingsMdnsEnabled = ref(false);
const settingsRequirePairConfirmation = ref(false);
const settingsSaving = ref(false);
const settingsError = ref(null);
async function loadSettings() {
    try {
        const s = await getSettings();
        settingsDownloadDir.value = s.downloadDirectory;
        settingsMdnsEnabled.value = !!s.mdnsEnabled;
        settingsRequirePairConfirmation.value = !!s.requirePairConfirmation;
    }
    catch { /* ignore */ }
}
async function saveDownloadDir() {
    const dir = settingsDownloadDir.value.trim();
    if (!dir)
        return;
    settingsSaving.value = true;
    settingsError.value = null;
    try {
        const s = await updateSettings({ downloadDirectory: dir });
        settingsDownloadDir.value = s.downloadDirectory;
        showSettings.value = false;
    }
    catch (e) {
        settingsError.value = e.message || 'Save failed';
    }
    finally {
        settingsSaving.value = false;
    }
}
/// Toggle mDNS broadcasting on the server. The server hot-swaps the
/// publisher; no restart required. We optimistically flip the toggle
/// and roll back on error so the user sees immediate feedback.
async function toggleMdns() {
    const next = !settingsMdnsEnabled.value;
    settingsSaving.value = true;
    settingsError.value = null;
    try {
        const s = await updateSettings({ mdnsEnabled: next });
        settingsMdnsEnabled.value = s.mdnsEnabled;
    }
    catch (e) {
        settingsError.value = e.message || 'mDNS toggle failed';
        // Keep the toggle at its previous position.
    }
    finally {
        settingsSaving.value = false;
    }
}
async function togglePairConfirmation() {
    const next = !settingsRequirePairConfirmation.value;
    settingsSaving.value = true;
    settingsError.value = null;
    try {
        const s = await updateSettings({ requirePairConfirmation: next });
        settingsRequirePairConfirmation.value = s.requirePairConfirmation;
    }
    catch (e) {
        settingsError.value = e.message || 'Pair confirmation toggle failed';
    }
    finally {
        settingsSaving.value = false;
    }
}
// ========== Lifecycle ==========
function cleanup() {
    if (qrTimer)
        clearInterval(qrTimer);
    if (countdownTimer)
        clearInterval(countdownTimer);
    if (pairPollTimer)
        clearInterval(pairPollTimer);
    wsClient?.close();
    peerPool.close();
}
/// Build the WS URL from the current page origin.
function wsUrlFromOrigin() {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    return `${proto}//${location.host}/ws/v1`;
}
/// Try to restore a previous session from sessionStorage.
/// Validates by calling listTransfers (requires auth). On failure,
/// clears the stale session and falls back to QR pairing.
async function tryRestoreSession() {
    const s = restoreSession();
    if (!s)
        return false;
    try {
        await listTransfers();
        isPaired.value = true;
        connectWS(s.sessionId, s.accessToken, wsUrlFromOrigin());
        return true;
    }
    catch {
        setSession(null);
        return false;
    }
}
onMounted(async () => {
    peerPool.restore();
    isPaired.value = peerViews.value.length > 0;
    await refreshQR();
    qrTimer = setInterval(refreshQR, 50_000);
    countdownTimer = setInterval(tickCountdown, 1000);
    pairPollTimer = setInterval(pollPairRequests, 2000);
    await loadHistory();
    await loadSettings();
});
onUnmounted(cleanup);
debugger; /* PartiallyEnd: #3632/scriptSetup.vue */
const __VLS_ctx = {};
let __VLS_components;
let __VLS_directives;
/** @type {__VLS_StyleScopedClasses['settings-btn']} */ ;
/** @type {__VLS_StyleScopedClasses['reconnect-btn']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-panel']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-input']} */ ;
/** @type {__VLS_StyleScopedClasses['switch']} */ ;
/** @type {__VLS_StyleScopedClasses['switch']} */ ;
/** @type {__VLS_StyleScopedClasses['switch']} */ ;
/** @type {__VLS_StyleScopedClasses['slider']} */ ;
/** @type {__VLS_StyleScopedClasses['switch']} */ ;
/** @type {__VLS_StyleScopedClasses['slider']} */ ;
/** @type {__VLS_StyleScopedClasses['switch']} */ ;
/** @type {__VLS_StyleScopedClasses['slider']} */ ;
/** @type {__VLS_StyleScopedClasses['switch']} */ ;
/** @type {__VLS_StyleScopedClasses['slider']} */ ;
/** @type {__VLS_StyleScopedClasses['ws-indicator']} */ ;
/** @type {__VLS_StyleScopedClasses['ws-dot']} */ ;
/** @type {__VLS_StyleScopedClasses['ws-indicator']} */ ;
/** @type {__VLS_StyleScopedClasses['ws-dot']} */ ;
/** @type {__VLS_StyleScopedClasses['ws-indicator']} */ ;
/** @type {__VLS_StyleScopedClasses['ws-dot']} */ ;
/** @type {__VLS_StyleScopedClasses['ws-indicator']} */ ;
/** @type {__VLS_StyleScopedClasses['ws-dot']} */ ;
/** @type {__VLS_StyleScopedClasses['modal-card']} */ ;
/** @type {__VLS_StyleScopedClasses['btn-accept']} */ ;
/** @type {__VLS_StyleScopedClasses['btn-reject']} */ ;
/** @type {__VLS_StyleScopedClasses['btn-cancel']} */ ;
/** @type {__VLS_StyleScopedClasses['qr']} */ ;
/** @type {__VLS_StyleScopedClasses['qr-error']} */ ;
/** @type {__VLS_StyleScopedClasses['btn']} */ ;
/** @type {__VLS_StyleScopedClasses['dropzone']} */ ;
/** @type {__VLS_StyleScopedClasses['dropzone']} */ ;
/** @type {__VLS_StyleScopedClasses['peer-panel']} */ ;
/** @type {__VLS_StyleScopedClasses['remote-pair-row']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-input']} */ ;
/** @type {__VLS_StyleScopedClasses['peer-choice']} */ ;
/** @type {__VLS_StyleScopedClasses['peer-dot']} */ ;
/** @type {__VLS_StyleScopedClasses['connected']} */ ;
/** @type {__VLS_StyleScopedClasses['peer-dot']} */ ;
/** @type {__VLS_StyleScopedClasses['connecting']} */ ;
/** @type {__VLS_StyleScopedClasses['peer-dot']} */ ;
/** @type {__VLS_StyleScopedClasses['reconnecting']} */ ;
/** @type {__VLS_StyleScopedClasses['offers']} */ ;
/** @type {__VLS_StyleScopedClasses['offer-files']} */ ;
/** @type {__VLS_StyleScopedClasses['transfers']} */ ;
/** @type {__VLS_StyleScopedClasses['progress-fill']} */ ;
/** @type {__VLS_StyleScopedClasses['progress-fill']} */ ;
/** @type {__VLS_StyleScopedClasses['progress-fill']} */ ;
/** @type {__VLS_StyleScopedClasses['progress-fill']} */ ;
/** @type {__VLS_StyleScopedClasses['modal-header']} */ ;
/** @type {__VLS_StyleScopedClasses['modal-close']} */ ;
/** @type {__VLS_StyleScopedClasses['history']} */ ;
/** @type {__VLS_StyleScopedClasses['history']} */ ;
/** @type {__VLS_StyleScopedClasses['history']} */ ;
/** @type {__VLS_StyleScopedClasses['history-status']} */ ;
/** @type {__VLS_StyleScopedClasses['completed']} */ ;
/** @type {__VLS_StyleScopedClasses['history-status']} */ ;
/** @type {__VLS_StyleScopedClasses['failed']} */ ;
/** @type {__VLS_StyleScopedClasses['history-status']} */ ;
/** @type {__VLS_StyleScopedClasses['history-status']} */ ;
/** @type {__VLS_StyleScopedClasses['history-status']} */ ;
// CSS variable injection 
// CSS variable injection end 
__VLS_asFunctionalElement(__VLS_intrinsicElements.main, __VLS_intrinsicElements.main)({
    ...{ class: "app" },
});
__VLS_asFunctionalElement(__VLS_intrinsicElements.header, __VLS_intrinsicElements.header)({});
__VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
    ...{ class: "header-row" },
});
__VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({});
__VLS_asFunctionalElement(__VLS_intrinsicElements.h1, __VLS_intrinsicElements.h1)({});
__VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({
    ...{ class: "server" },
});
(__VLS_ctx.serverName);
__VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
    ...{ class: "header-actions" },
});
if (__VLS_ctx.isPaired) {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
        ...{ onClick: (__VLS_ctx.handleReconnect) },
        ...{ class: "reconnect-btn" },
        title: "作废当前配对，重新显示二维码（用于换手机或会话失効）",
    });
}
__VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
    ...{ onClick: (...[$event]) => {
            __VLS_ctx.showSettings = !__VLS_ctx.showSettings;
        } },
    ...{ class: "settings-btn" },
    title: "Settings",
});
__VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
    ...{ class: "ws-indicator" },
    ...{ class: (__VLS_ctx.wsStatus) },
    title: (`WebSocket: ${__VLS_ctx.wsStatus}`),
});
__VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
    ...{ class: "ws-dot" },
});
__VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
    ...{ class: "ws-label" },
});
(__VLS_ctx.wsStatus);
if (__VLS_ctx.isPaired) {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "ws-indicator phone" },
        ...{ class: (__VLS_ctx.phoneConnected ? 'connected' : 'disconnected') },
        title: (__VLS_ctx.phoneConnected ? `${__VLS_ctx.phoneName} 已连接` : '暂无在线设备'),
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
        ...{ class: "ws-dot" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
        ...{ class: "ws-label" },
    });
    (__VLS_ctx.phoneConnected ? (__VLS_ctx.phoneName || '设备') : '设备离线');
}
if (__VLS_ctx.showSettings) {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.section, __VLS_intrinsicElements.section)({
        ...{ class: "settings-panel" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.h3, __VLS_intrinsicElements.h3)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "settings-field" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.label, __VLS_intrinsicElements.label)({
        for: "downloadDir",
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "settings-input-row" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.input)({
        id: "downloadDir",
        value: (__VLS_ctx.settingsDownloadDir),
        type: "text",
        ...{ class: "settings-input" },
        placeholder: "\u0043\u003a\u005c\u0055\u0073\u0065\u0072\u0073\u005c\u002e\u002e\u002e\u005c\u0044\u006f\u0077\u006e\u006c\u006f\u0061\u0064\u0073\u005c\u0046\u0061\u0073\u0074\u0044\u0072\u006f\u0070",
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
        ...{ onClick: (__VLS_ctx.saveDownloadDir) },
        ...{ class: "btn btn-accept" },
        disabled: (__VLS_ctx.settingsSaving),
    });
    (__VLS_ctx.settingsSaving ? 'Saving...' : 'Save');
    if (__VLS_ctx.settingsError) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({
            ...{ class: "settings-error" },
        });
        (__VLS_ctx.settingsError);
    }
    __VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({
        ...{ class: "settings-hint" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "settings-field" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.label, __VLS_intrinsicElements.label)({
        ...{ class: "settings-toggle-row" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.strong, __VLS_intrinsicElements.strong)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
        ...{ class: "settings-hint" },
        ...{ style: {} },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.label, __VLS_intrinsicElements.label)({
        ...{ class: "switch" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.input)({
        ...{ onChange: (__VLS_ctx.toggleMdns) },
        type: "checkbox",
        checked: (__VLS_ctx.settingsMdnsEnabled),
        disabled: (__VLS_ctx.settingsSaving),
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
        ...{ class: "slider" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "settings-field" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.label, __VLS_intrinsicElements.label)({
        ...{ class: "settings-toggle-row" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.strong, __VLS_intrinsicElements.strong)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
        ...{ class: "settings-hint" },
        ...{ style: {} },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.label, __VLS_intrinsicElements.label)({
        ...{ class: "switch" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.input)({
        ...{ onChange: (__VLS_ctx.togglePairConfirmation) },
        type: "checkbox",
        checked: (__VLS_ctx.settingsRequirePairConfirmation),
        disabled: (__VLS_ctx.settingsSaving),
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
        ...{ class: "slider" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({
        ...{ class: "settings-hint" },
    });
}
const __VLS_0 = {}.Teleport;
/** @type {[typeof __VLS_components.Teleport, typeof __VLS_components.Teleport, ]} */ ;
// @ts-ignore
const __VLS_1 = __VLS_asFunctionalComponent(__VLS_0, new __VLS_0({
    to: "body",
}));
const __VLS_2 = __VLS_1({
    to: "body",
}, ...__VLS_functionalComponentArgsRest(__VLS_1));
__VLS_3.slots.default;
if (__VLS_ctx.showPairDialog && __VLS_ctx.pendingRequests.length) {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ onClick: (() => { }) },
        ...{ class: "modal-overlay" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "modal-card" },
        role: "dialog",
        'aria-label': "Pairing Request",
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "modal-header" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.h2, __VLS_intrinsicElements.h2)({});
    __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
        ...{ onClick: (...[$event]) => {
                if (!(__VLS_ctx.showPairDialog && __VLS_ctx.pendingRequests.length))
                    return;
                __VLS_ctx.showPairDialog = false;
            } },
        ...{ class: "modal-close" },
        'aria-label': "Close",
    });
    for (const [req] of __VLS_getVForSourceType((__VLS_ctx.pendingRequests))) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            key: (req.requestId),
            ...{ class: "pair-request-item" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "pair-device-icon" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "pair-device-info" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.strong, __VLS_intrinsicElements.strong)({});
        (req.deviceName || 'Unknown Device');
        __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
            ...{ class: "pair-platform" },
        });
        (req.platform || 'unknown');
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "pair-actions" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
            ...{ onClick: (...[$event]) => {
                    if (!(__VLS_ctx.showPairDialog && __VLS_ctx.pendingRequests.length))
                        return;
                    __VLS_ctx.handleAccept(req.requestId);
                } },
            ...{ class: "btn btn-accept" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
            ...{ onClick: (...[$event]) => {
                    if (!(__VLS_ctx.showPairDialog && __VLS_ctx.pendingRequests.length))
                        return;
                    __VLS_ctx.handleReject(req.requestId);
                } },
            ...{ class: "btn btn-reject" },
        });
    }
}
var __VLS_3;
__VLS_asFunctionalElement(__VLS_intrinsicElements.section, __VLS_intrinsicElements.section)({
    ...{ class: "qr" },
});
if (__VLS_ctx.qrLoading && !__VLS_ctx.qrDataUrl) {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "qr-loading" },
    });
}
else if (__VLS_ctx.qrError) {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "qr-error" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({});
    (__VLS_ctx.qrError);
    __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
        ...{ onClick: (__VLS_ctx.refreshQR) },
        ...{ class: "btn btn-accept" },
    });
}
else if (__VLS_ctx.qrPayload) {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.img)({
        src: (__VLS_ctx.qrDataUrl),
        alt: "QR Code",
    });
    if (__VLS_ctx.countdown > 0) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({});
        (__VLS_ctx.countdown);
    }
    __VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({
        ...{ class: "address" },
    });
    (__VLS_ctx.qrPayload.host);
    (__VLS_ctx.qrPayload.port);
}
__VLS_asFunctionalElement(__VLS_intrinsicElements.section, __VLS_intrinsicElements.section)({
    ...{ class: "peer-panel" },
});
__VLS_asFunctionalElement(__VLS_intrinsicElements.h3, __VLS_intrinsicElements.h3)({});
(__VLS_ctx.connectedPeerCount);
__VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
    ...{ class: "remote-pair-row" },
});
__VLS_asFunctionalElement(__VLS_intrinsicElements.input)({
    ...{ onKeyup: (__VLS_ctx.connectRemotePeer) },
    ...{ class: "settings-input" },
    placeholder: "输入对方 IP，例如 192.168.1.23:9527",
});
(__VLS_ctx.remoteAddress);
__VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
    ...{ onClick: (__VLS_ctx.connectRemotePeer) },
    ...{ class: "btn btn-accept" },
    disabled: (__VLS_ctx.remotePairing),
});
(__VLS_ctx.remotePairing ? '等待确认…' : '连接设备');
if (__VLS_ctx.remotePairStatus) {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({
        ...{ class: "status" },
    });
    (__VLS_ctx.remotePairStatus);
}
if (__VLS_ctx.peerViews.length) {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
        ...{ class: "peer-list" },
    });
    for (const [peer] of __VLS_getVForSourceType((__VLS_ctx.peerViews))) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.label, __VLS_intrinsicElements.label)({
            key: (peer.id),
            ...{ class: "peer-choice" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.input)({
            type: "checkbox",
            value: (peer.id),
            disabled: (peer.status !== 'connected'),
        });
        (__VLS_ctx.selectedRecipientIds);
        __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
            ...{ class: "peer-dot" },
            ...{ class: (peer.status) },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
        (peer.name);
        __VLS_asFunctionalElement(__VLS_intrinsicElements.small, __VLS_intrinsicElements.small)({});
        (peer.platform);
        (peer.status);
        __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
            ...{ onClick: (...[$event]) => {
                    if (!(__VLS_ctx.peerViews.length))
                        return;
                    __VLS_ctx.peerPool.removePeer(peer.id);
                } },
            type: "button",
            ...{ class: "peer-remove" },
        });
    }
}
else {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({
        ...{ class: "settings-hint" },
    });
}
__VLS_asFunctionalElement(__VLS_intrinsicElements.section, __VLS_intrinsicElements.section)({
    ...{ onDragover: (__VLS_ctx.handleDragOver) },
    ...{ onDragleave: (__VLS_ctx.handleDragLeave) },
    ...{ onDrop: (__VLS_ctx.handleDrop) },
    ...{ onClick: (__VLS_ctx.openFilePicker) },
    ...{ class: "dropzone" },
    ...{ class: ({ active: __VLS_ctx.dragOver }) },
    role: "button",
    tabindex: "0",
    'aria-label': "Drop files here or click to browse",
});
__VLS_asFunctionalElement(__VLS_intrinsicElements.input)({
    ...{ onChange: (__VLS_ctx.handleFilePickerChange) },
    ref: "fileInput",
    type: "file",
    multiple: true,
    ...{ style: {} },
});
/** @type {typeof __VLS_ctx.fileInput} */ ;
if (__VLS_ctx.uploadStatus) {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({
        ...{ class: "status" },
    });
    (__VLS_ctx.uploadStatus);
}
if (__VLS_ctx.incomingOffers.length) {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.section, __VLS_intrinsicElements.section)({
        ...{ class: "offers" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.h3, __VLS_intrinsicElements.h3)({});
    for (const [offer] of __VLS_getVForSourceType((__VLS_ctx.incomingOffers))) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            key: (`${offer.peerId}:${offer.transferId}`),
            ...{ class: "offer-card" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "offer-header" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
            ...{ class: "offer-from" },
        });
        (offer.deviceName);
        __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
            ...{ class: "offer-count" },
        });
        (offer.files.length);
        __VLS_asFunctionalElement(__VLS_intrinsicElements.ul, __VLS_intrinsicElements.ul)({
            ...{ class: "offer-files" },
        });
        for (const [f] of __VLS_getVForSourceType((offer.files))) {
            __VLS_asFunctionalElement(__VLS_intrinsicElements.li, __VLS_intrinsicElements.li)({
                key: (f.fileId),
            });
            (f.name);
            (__VLS_ctx.formatSize(f.size));
        }
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "offer-actions" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
            ...{ onClick: (...[$event]) => {
                    if (!(__VLS_ctx.incomingOffers.length))
                        return;
                    __VLS_ctx.acceptOffer(offer);
                } },
            ...{ class: "btn btn-accept" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
            ...{ onClick: (...[$event]) => {
                    if (!(__VLS_ctx.incomingOffers.length))
                        return;
                    __VLS_ctx.rejectOffer(offer);
                } },
            ...{ class: "btn btn-reject" },
        });
    }
}
if (__VLS_ctx.activeTransfers.length) {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.section, __VLS_intrinsicElements.section)({
        ...{ class: "transfers" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.h3, __VLS_intrinsicElements.h3)({});
    for (const [t] of __VLS_getVForSourceType((__VLS_ctx.activeTransfers))) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            key: (`${t.peerId}:${t.transferId}:${t.fileId}`),
            ...{ class: "transfer-item" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "transfer-info" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
            ...{ class: "transfer-name" },
        });
        (t.filename);
        (t.peerName);
        __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
            ...{ class: "transfer-status" },
        });
        (t.status);
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "progress-bar" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "progress-fill" },
            ...{ class: (t.status) },
            ...{ style: ({ width: __VLS_ctx.progressPercent(t) + '%' }) },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "transfer-details" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({});
        (__VLS_ctx.formatSize(t.transferredBytes));
        (__VLS_ctx.formatSize(t.totalBytes));
        if (t.status === 'transferring' && t.speedBps > 0) {
            __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
                ...{ class: "transfer-speed" },
            });
            (__VLS_ctx.formatSpeed(t.speedBps));
        }
        if (t.status === 'completed') {
            __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
                ...{ class: "done-label" },
            });
        }
        if (t.status === 'failed') {
            __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
                ...{ class: "error-label" },
                title: (t.error),
            });
        }
        __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
            ...{ class: "transfer-actions" },
        });
        if (t.status === 'transferring') {
            __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
                ...{ onClick: (...[$event]) => {
                        if (!(__VLS_ctx.activeTransfers.length))
                            return;
                        if (!(t.status === 'transferring'))
                            return;
                        __VLS_ctx.pauseTransfer(t.transferId);
                    } },
                ...{ class: "btn-cancel" },
            });
        }
        if (t.status === 'paused') {
            __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
                ...{ onClick: (...[$event]) => {
                        if (!(__VLS_ctx.activeTransfers.length))
                            return;
                        if (!(t.status === 'paused'))
                            return;
                        __VLS_ctx.resumeTransfer(t.transferId);
                    } },
                ...{ class: "btn-cancel" },
            });
        }
        if (t.status === 'transferring' || t.status === 'paused') {
            __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
                ...{ onClick: (...[$event]) => {
                        if (!(__VLS_ctx.activeTransfers.length))
                            return;
                        if (!(t.status === 'transferring' || t.status === 'paused'))
                            return;
                        __VLS_ctx.cancelTransfer(t.transferId);
                    } },
                ...{ class: "btn-cancel" },
            });
        }
        if (t.status === 'failed') {
            __VLS_asFunctionalElement(__VLS_intrinsicElements.button, __VLS_intrinsicElements.button)({
                ...{ onClick: (...[$event]) => {
                        if (!(__VLS_ctx.activeTransfers.length))
                            return;
                        if (!(t.status === 'failed'))
                            return;
                        __VLS_ctx.retryTransfer(t.transferId);
                    } },
                ...{ class: "btn-cancel" },
            });
        }
    }
}
__VLS_asFunctionalElement(__VLS_intrinsicElements.section, __VLS_intrinsicElements.section)({
    ...{ class: "history" },
});
__VLS_asFunctionalElement(__VLS_intrinsicElements.h3, __VLS_intrinsicElements.h3)({});
if (__VLS_ctx.historyLoading) {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
        ...{ class: "history-loading" },
    });
}
__VLS_asFunctionalElement(__VLS_intrinsicElements.ul, __VLS_intrinsicElements.ul)({});
for (const [t] of __VLS_getVForSourceType((__VLS_ctx.transfers))) {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.li, __VLS_intrinsicElements.li)({
        key: (t.id),
        ...{ class: "history-item" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
        ...{ class: "history-status" },
        ...{ class: (t.status) },
    });
    (t.status);
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
        ...{ class: "history-dir" },
    });
    (t.direction === 'client_to_server' ? '📥' : '📤');
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
        ...{ class: "history-size" },
    });
    (__VLS_ctx.formatSize(t.transferredBytes));
    (__VLS_ctx.formatSize(t.totalBytes));
    __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
        ...{ class: "history-time" },
    });
    (t.createdAt ? new Date(t.createdAt * 1000).toLocaleTimeString() : '');
    if (t.errorMessage) {
        __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
            ...{ class: "history-error" },
            title: (t.errorMessage),
        });
    }
}
if (__VLS_ctx.transfers.length === 0 && !__VLS_ctx.historyLoading) {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.li, __VLS_intrinsicElements.li)({});
}
/** @type {__VLS_StyleScopedClasses['app']} */ ;
/** @type {__VLS_StyleScopedClasses['header-row']} */ ;
/** @type {__VLS_StyleScopedClasses['server']} */ ;
/** @type {__VLS_StyleScopedClasses['header-actions']} */ ;
/** @type {__VLS_StyleScopedClasses['reconnect-btn']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-btn']} */ ;
/** @type {__VLS_StyleScopedClasses['ws-indicator']} */ ;
/** @type {__VLS_StyleScopedClasses['ws-dot']} */ ;
/** @type {__VLS_StyleScopedClasses['ws-label']} */ ;
/** @type {__VLS_StyleScopedClasses['ws-indicator']} */ ;
/** @type {__VLS_StyleScopedClasses['phone']} */ ;
/** @type {__VLS_StyleScopedClasses['ws-dot']} */ ;
/** @type {__VLS_StyleScopedClasses['ws-label']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-panel']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-field']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-input-row']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-input']} */ ;
/** @type {__VLS_StyleScopedClasses['btn']} */ ;
/** @type {__VLS_StyleScopedClasses['btn-accept']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-error']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-hint']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-field']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-toggle-row']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-hint']} */ ;
/** @type {__VLS_StyleScopedClasses['switch']} */ ;
/** @type {__VLS_StyleScopedClasses['slider']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-field']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-toggle-row']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-hint']} */ ;
/** @type {__VLS_StyleScopedClasses['switch']} */ ;
/** @type {__VLS_StyleScopedClasses['slider']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-hint']} */ ;
/** @type {__VLS_StyleScopedClasses['modal-overlay']} */ ;
/** @type {__VLS_StyleScopedClasses['modal-card']} */ ;
/** @type {__VLS_StyleScopedClasses['modal-header']} */ ;
/** @type {__VLS_StyleScopedClasses['modal-close']} */ ;
/** @type {__VLS_StyleScopedClasses['pair-request-item']} */ ;
/** @type {__VLS_StyleScopedClasses['pair-device-icon']} */ ;
/** @type {__VLS_StyleScopedClasses['pair-device-info']} */ ;
/** @type {__VLS_StyleScopedClasses['pair-platform']} */ ;
/** @type {__VLS_StyleScopedClasses['pair-actions']} */ ;
/** @type {__VLS_StyleScopedClasses['btn']} */ ;
/** @type {__VLS_StyleScopedClasses['btn-accept']} */ ;
/** @type {__VLS_StyleScopedClasses['btn']} */ ;
/** @type {__VLS_StyleScopedClasses['btn-reject']} */ ;
/** @type {__VLS_StyleScopedClasses['qr']} */ ;
/** @type {__VLS_StyleScopedClasses['qr-loading']} */ ;
/** @type {__VLS_StyleScopedClasses['qr-error']} */ ;
/** @type {__VLS_StyleScopedClasses['btn']} */ ;
/** @type {__VLS_StyleScopedClasses['btn-accept']} */ ;
/** @type {__VLS_StyleScopedClasses['address']} */ ;
/** @type {__VLS_StyleScopedClasses['peer-panel']} */ ;
/** @type {__VLS_StyleScopedClasses['remote-pair-row']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-input']} */ ;
/** @type {__VLS_StyleScopedClasses['btn']} */ ;
/** @type {__VLS_StyleScopedClasses['btn-accept']} */ ;
/** @type {__VLS_StyleScopedClasses['status']} */ ;
/** @type {__VLS_StyleScopedClasses['peer-list']} */ ;
/** @type {__VLS_StyleScopedClasses['peer-choice']} */ ;
/** @type {__VLS_StyleScopedClasses['peer-dot']} */ ;
/** @type {__VLS_StyleScopedClasses['peer-remove']} */ ;
/** @type {__VLS_StyleScopedClasses['settings-hint']} */ ;
/** @type {__VLS_StyleScopedClasses['dropzone']} */ ;
/** @type {__VLS_StyleScopedClasses['status']} */ ;
/** @type {__VLS_StyleScopedClasses['offers']} */ ;
/** @type {__VLS_StyleScopedClasses['offer-card']} */ ;
/** @type {__VLS_StyleScopedClasses['offer-header']} */ ;
/** @type {__VLS_StyleScopedClasses['offer-from']} */ ;
/** @type {__VLS_StyleScopedClasses['offer-count']} */ ;
/** @type {__VLS_StyleScopedClasses['offer-files']} */ ;
/** @type {__VLS_StyleScopedClasses['offer-actions']} */ ;
/** @type {__VLS_StyleScopedClasses['btn']} */ ;
/** @type {__VLS_StyleScopedClasses['btn-accept']} */ ;
/** @type {__VLS_StyleScopedClasses['btn']} */ ;
/** @type {__VLS_StyleScopedClasses['btn-reject']} */ ;
/** @type {__VLS_StyleScopedClasses['transfers']} */ ;
/** @type {__VLS_StyleScopedClasses['transfer-item']} */ ;
/** @type {__VLS_StyleScopedClasses['transfer-info']} */ ;
/** @type {__VLS_StyleScopedClasses['transfer-name']} */ ;
/** @type {__VLS_StyleScopedClasses['transfer-status']} */ ;
/** @type {__VLS_StyleScopedClasses['progress-bar']} */ ;
/** @type {__VLS_StyleScopedClasses['progress-fill']} */ ;
/** @type {__VLS_StyleScopedClasses['transfer-details']} */ ;
/** @type {__VLS_StyleScopedClasses['transfer-speed']} */ ;
/** @type {__VLS_StyleScopedClasses['done-label']} */ ;
/** @type {__VLS_StyleScopedClasses['error-label']} */ ;
/** @type {__VLS_StyleScopedClasses['transfer-actions']} */ ;
/** @type {__VLS_StyleScopedClasses['btn-cancel']} */ ;
/** @type {__VLS_StyleScopedClasses['btn-cancel']} */ ;
/** @type {__VLS_StyleScopedClasses['btn-cancel']} */ ;
/** @type {__VLS_StyleScopedClasses['btn-cancel']} */ ;
/** @type {__VLS_StyleScopedClasses['history']} */ ;
/** @type {__VLS_StyleScopedClasses['history-loading']} */ ;
/** @type {__VLS_StyleScopedClasses['history-item']} */ ;
/** @type {__VLS_StyleScopedClasses['history-status']} */ ;
/** @type {__VLS_StyleScopedClasses['history-dir']} */ ;
/** @type {__VLS_StyleScopedClasses['history-size']} */ ;
/** @type {__VLS_StyleScopedClasses['history-time']} */ ;
/** @type {__VLS_StyleScopedClasses['history-error']} */ ;
var __VLS_dollars;
const __VLS_self = (await import('vue')).defineComponent({
    setup() {
        return {
            peerPool: peerPool,
            peerViews: peerViews,
            selectedRecipientIds: selectedRecipientIds,
            connectedPeerCount: connectedPeerCount,
            qrDataUrl: qrDataUrl,
            qrPayload: qrPayload,
            countdown: countdown,
            serverName: serverName,
            qrLoading: qrLoading,
            qrError: qrError,
            refreshQR: refreshQR,
            dragOver: dragOver,
            uploadStatus: uploadStatus,
            fileInput: fileInput,
            handleDragOver: handleDragOver,
            handleDragLeave: handleDragLeave,
            handleDrop: handleDrop,
            openFilePicker: openFilePicker,
            handleFilePickerChange: handleFilePickerChange,
            pendingRequests: pendingRequests,
            showPairDialog: showPairDialog,
            isPaired: isPaired,
            remoteAddress: remoteAddress,
            remotePairStatus: remotePairStatus,
            remotePairing: remotePairing,
            connectRemotePeer: connectRemotePeer,
            handleAccept: handleAccept,
            handleReject: handleReject,
            handleReconnect: handleReconnect,
            wsStatus: wsStatus,
            phoneConnected: phoneConnected,
            phoneName: phoneName,
            incomingOffers: incomingOffers,
            activeTransfers: activeTransfers,
            pauseTransfer: pauseTransfer,
            resumeTransfer: resumeTransfer,
            retryTransfer: retryTransfer,
            acceptOffer: acceptOffer,
            rejectOffer: rejectOffer,
            cancelTransfer: cancelTransfer,
            transfers: transfers,
            historyLoading: historyLoading,
            formatSize: formatSize,
            formatSpeed: formatSpeed,
            progressPercent: progressPercent,
            showSettings: showSettings,
            settingsDownloadDir: settingsDownloadDir,
            settingsMdnsEnabled: settingsMdnsEnabled,
            settingsRequirePairConfirmation: settingsRequirePairConfirmation,
            settingsSaving: settingsSaving,
            settingsError: settingsError,
            saveDownloadDir: saveDownloadDir,
            toggleMdns: toggleMdns,
            togglePairConfirmation: togglePairConfirmation,
        };
    },
});
export default (await import('vue')).defineComponent({
    setup() {
        return {};
    },
});
; /* PartiallyEnd: #4569/main.vue */
