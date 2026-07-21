import { onMounted, onUnmounted, ref } from 'vue';
import QRCode from 'qrcode';
import { acceptPair, createTransfer, fetchQR, getTransfer, listPairRequests, listTransfers, rejectPair, setSession, uploadChunk, } from './api';
import { useWebSocket } from './composables/useWebSocket';
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
    if (isPaired.value)
        return;
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
    if (countdown.value === 0 && !isPaired.value)
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
    if (!isPaired.value || !wsClient) {
        uploadStatus.value = 'Pair a phone first before sending files.';
        return;
    }
    uploadStatus.value = `Preparing ${files.length} file(s)...`;
    for (const f of files) {
        try {
            await stageAndOfferFile(f);
        }
        catch (e) {
            uploadStatus.value = `Failed: ${e.message}`;
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
async function pollPairRequests() {
    if (isPaired.value)
        return;
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
        setSession({
            sessionId: res.session.sessionId,
            accessToken: res.session.accessToken,
        });
        showPairDialog.value = false;
        pendingRequests.value = [];
        isPaired.value = true;
        if (res.session.websocketUrl) {
            connectWS(res.session.sessionId, res.session.accessToken, res.session.websocketUrl);
        }
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
// ========== WebSocket ==========
const wsStatus = ref('disconnected');
let wsClient = null;
const incomingOffers = ref([]);
const activeTransfers = ref([]);
function pauseTransfer(transferId) {
    const t = activeTransfers.value.find((t) => t.transferId === transferId);
    if (t)
        t.status = 'paused';
    wsClient?.send({
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
    wsClient?.send({
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
                isPaired.value = false;
                wsStatus.value = 'disconnected';
                activeTransfers.value = [];
                incomingOffers.value = [];
                wsClient = null;
                refreshQR();
            },
        },
    });
    wsStatus.value = 'connecting';
}
function handleWSMessage(raw) {
    const msg = raw;
    if (!msg?.type)
        return;
    const p = (msg.payload ?? {});
    switch (msg.type) {
        case 'file.offer': {
            incomingOffers.value.push({
                transferId: p.transferId,
                deviceName: p.deviceName || 'Phone',
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
        case 'device.disconnect': {
            // Phone disconnected — mark active transfers accordingly.
            for (const t of activeTransfers.value) {
                if (t.status === 'transferring' || t.status === 'paused') {
                    t.status = 'failed';
                    t.error = 'Device disconnected';
                }
            }
            break;
        }
        case 'session.revoked': {
            // Session was revoked — reset all state.
            isPaired.value = false;
            activeTransfers.value = [];
            incomingOffers.value = [];
            wsClient?.close();
            wsClient = null;
            wsStatus.value = 'disconnected';
            refreshQR();
            break;
        }
    }
}
async function acceptOffer(offer) {
    incomingOffers.value = incomingOffers.value.filter((o) => o.transferId !== offer.transferId);
    for (const f of offer.files) {
        activeTransfers.value.push({
            transferId: offer.transferId,
            fileId: f.fileId,
            filename: f.name,
            totalBytes: f.size,
            transferredBytes: 0,
            speedBps: 0,
            status: 'transferring',
        });
    }
    wsClient?.send({
        version: 1,
        type: 'file.offer.accept',
        messageId: crypto.randomUUID(),
        timestamp: Date.now(),
        payload: { offerId: offer.transferId },
    });
    // The transfer may have already completed before the user clicked
    // Accept (small files upload in <200 ms). Poll the server once to
    // sync the real status so the UI doesn't stick on "transferring".
    try {
        const row = await getTransfer(offer.transferId);
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
    wsClient?.send({
        version: 1,
        type: 'file.offer.reject',
        messageId: crypto.randomUUID(),
        timestamp: Date.now(),
        payload: { offerId: offer.transferId, reason: 'user_rejected' },
    });
}
function cancelTransfer(transferId) {
    activeTransfers.value = activeTransfers.value.filter((t) => t.transferId !== transferId);
    wsClient?.send({
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
        transfers.value = await listTransfers();
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
// ========== Lifecycle ==========
function cleanup() {
    if (qrTimer)
        clearInterval(qrTimer);
    if (countdownTimer)
        clearInterval(countdownTimer);
    if (pairPollTimer)
        clearInterval(pairPollTimer);
    wsClient?.close();
}
onMounted(async () => {
    await refreshQR();
    qrTimer = setInterval(refreshQR, 50_000);
    countdownTimer = setInterval(tickCountdown, 1000);
    pairPollTimer = setInterval(pollPairRequests, 2000);
    await loadHistory();
});
onUnmounted(cleanup);
debugger; /* PartiallyEnd: #3632/scriptSetup.vue */
const __VLS_ctx = {};
let __VLS_components;
let __VLS_directives;
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
__VLS_asFunctionalElement(__VLS_intrinsicElements.h1, __VLS_intrinsicElements.h1)({});
__VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({
    ...{ class: "server" },
});
(__VLS_ctx.serverName);
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
if (!__VLS_ctx.isPaired) {
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
            key: (offer.transferId),
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
            key: (t.transferId),
            ...{ class: "transfer-item" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.div, __VLS_intrinsicElements.div)({
            ...{ class: "transfer-info" },
        });
        __VLS_asFunctionalElement(__VLS_intrinsicElements.span, __VLS_intrinsicElements.span)({
            ...{ class: "transfer-name" },
        });
        (t.filename);
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
/** @type {__VLS_StyleScopedClasses['server']} */ ;
/** @type {__VLS_StyleScopedClasses['ws-indicator']} */ ;
/** @type {__VLS_StyleScopedClasses['ws-dot']} */ ;
/** @type {__VLS_StyleScopedClasses['ws-label']} */ ;
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
            handleAccept: handleAccept,
            handleReject: handleReject,
            wsStatus: wsStatus,
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
        };
    },
});
export default (await import('vue')).defineComponent({
    setup() {
        return {};
    },
});
; /* PartiallyEnd: #4569/main.vue */
