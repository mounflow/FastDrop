import { onMounted, onUnmounted, ref } from 'vue';
import QRCode from 'qrcode';
import { completeFile, createTransfer, fetchQR, listTransfers, pollPairStatus, uploadChunk, } from './api';
import { useWebSocket } from './composables/useWebSocket';
const qrDataUrl = ref('');
const qrPayload = ref(null);
const countdown = ref(0);
const pairRequestId = ref(null);
const pairStatus = ref('idle');
const serverName = ref('FastDrop-PC');
const transfers = ref([]);
const downloadDir = ref('');
const dragOver = ref(false);
const uploadStatus = ref('');
let qrTimer = null;
let pollTimer = null;
let countdownTimer = null;
async function refreshQR() {
    try {
        const payload = await fetchQR();
        qrPayload.value = payload;
        serverName.value = payload.serverName;
        countdown.value = Math.max(0, payload.expiresAt - Math.floor(Date.now() / 1000));
        qrDataUrl.value = await QRCode.toDataURL(JSON.stringify(payload), { width: 256 });
    }
    catch (e) {
        console.error(e);
    }
}
async function pollPair() {
    if (!pairRequestId.value)
        return;
    try {
        const res = await pollPairStatus(pairRequestId.value);
        pairStatus.value = res.status;
        if (res.status === 'accepted' || res.status === 'rejected' || res.status === 'expired') {
            if (qrTimer)
                clearInterval(qrTimer);
            if (pollTimer)
                clearInterval(pollTimer);
            if (countdownTimer)
                clearInterval(countdownTimer);
        }
    }
    catch (e) {
        console.error(e);
    }
}
function tickCountdown() {
    if (countdown.value > 0)
        countdown.value--;
    if (countdown.value === 0 && pairRequestId.value === null)
        refreshQR();
}
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
    uploadStatus.value = `准备上传 ${files.length} 个文件...`;
    // Phase 1: PC -> phone uses server_to_client direction. The complete
    // path depends on the Android client; we only register the transfer
    // and surface an offer over WS to any connected device.
    for (const f of files) {
        try {
            // For demonstration, the file is uploaded as if direction=client_to_server
            // since the server treats it as an inbound batch from this PC. The
            // spec's PC->phone flow goes via file.offer + Range download, which is
            // tracked separately.
            await uploadFileToServer(f);
        }
        catch (e) {
            uploadStatus.value = `失败：${e.message}`;
        }
    }
}
async function uploadFileToServer(file) {
    // Create the transfer batch.
    const createBody = {
        offerId: crypto.randomUUID(),
        direction: 'client_to_server',
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
        uploadStatus.value = `${file.name}: ${i + 1}/${f.totalChunks} 块`;
    }
    // Compute SHA-256 of the file (browser crypto).
    const hash = await sha256(file);
    await completeFile(`/api/v1/transfers/${res.transferId}/files/${f.fileId}/complete`, file.size, hash);
    uploadStatus.value = `${file.name} 完成 ✓`;
}
async function sha256(file) {
    const buf = await file.arrayBuffer();
    const digest = await crypto.subtle.digest('SHA-256', buf);
    return Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, '0')).join('');
}
let wsClient = null;
function setupWS(sessionId, accessToken, wsUrl) {
    wsClient = useWebSocket({
        url: wsUrl,
        sessionId,
        accessToken,
        handlers: {
            onMessage: (msg) => {
                // The PC UI listens for incoming file.offer from phones so it can
                // pop an accept dialog. For Phase 1 we auto-accept.
                if (msg?.type === 'file.offer') {
                    pairStatus.value = 'incoming-offer';
                }
            },
        },
    });
}
async function loadHistory() {
    try {
        transfers.value = await listTransfers();
    }
    catch {
        transfers.value = [];
    }
}
function cleanup() {
    if (qrTimer)
        clearInterval(qrTimer);
    if (pollTimer)
        clearInterval(pollTimer);
    if (countdownTimer)
        clearInterval(countdownTimer);
    wsClient?.close();
}
onMounted(async () => {
    await refreshQR();
    qrTimer = setInterval(refreshQR, 50_000); // refresh 10s before expiry
    countdownTimer = setInterval(tickCountdown, 1000);
    await loadHistory();
});
onUnmounted(cleanup);
debugger; /* PartiallyEnd: #3632/scriptSetup.vue */
const __VLS_ctx = {};
let __VLS_components;
let __VLS_directives;
/** @type {__VLS_StyleScopedClasses['qr']} */ ;
/** @type {__VLS_StyleScopedClasses['dropzone']} */ ;
/** @type {__VLS_StyleScopedClasses['history']} */ ;
/** @type {__VLS_StyleScopedClasses['history']} */ ;
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
if (__VLS_ctx.qrPayload) {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.section, __VLS_intrinsicElements.section)({
        ...{ class: "qr" },
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.img)({
        src: (__VLS_ctx.qrDataUrl),
        alt: "二维码",
    });
    __VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({});
    (__VLS_ctx.countdown);
    __VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({
        ...{ class: "address" },
    });
    (__VLS_ctx.qrPayload.host);
    (__VLS_ctx.qrPayload.port);
}
__VLS_asFunctionalElement(__VLS_intrinsicElements.section, __VLS_intrinsicElements.section)({
    ...{ onDragover: (__VLS_ctx.handleDragOver) },
    ...{ onDragleave: (__VLS_ctx.handleDragLeave) },
    ...{ onDrop: (__VLS_ctx.handleDrop) },
    ...{ class: "dropzone" },
    ...{ class: ({ active: __VLS_ctx.dragOver }) },
});
if (__VLS_ctx.uploadStatus) {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.p, __VLS_intrinsicElements.p)({
        ...{ class: "status" },
    });
    (__VLS_ctx.uploadStatus);
}
__VLS_asFunctionalElement(__VLS_intrinsicElements.section, __VLS_intrinsicElements.section)({
    ...{ class: "history" },
});
__VLS_asFunctionalElement(__VLS_intrinsicElements.h3, __VLS_intrinsicElements.h3)({});
__VLS_asFunctionalElement(__VLS_intrinsicElements.ul, __VLS_intrinsicElements.ul)({});
for (const [t] of __VLS_getVForSourceType((__VLS_ctx.transfers))) {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.li, __VLS_intrinsicElements.li)({
        key: (t.id),
    });
    (t.id.slice(0, 8));
    (t.status);
    (t.transferredBytes);
    (t.totalBytes);
}
if (__VLS_ctx.transfers.length === 0) {
    __VLS_asFunctionalElement(__VLS_intrinsicElements.li, __VLS_intrinsicElements.li)({});
}
/** @type {__VLS_StyleScopedClasses['app']} */ ;
/** @type {__VLS_StyleScopedClasses['server']} */ ;
/** @type {__VLS_StyleScopedClasses['qr']} */ ;
/** @type {__VLS_StyleScopedClasses['address']} */ ;
/** @type {__VLS_StyleScopedClasses['dropzone']} */ ;
/** @type {__VLS_StyleScopedClasses['status']} */ ;
/** @type {__VLS_StyleScopedClasses['history']} */ ;
var __VLS_dollars;
const __VLS_self = (await import('vue')).defineComponent({
    setup() {
        return {
            qrDataUrl: qrDataUrl,
            qrPayload: qrPayload,
            countdown: countdown,
            serverName: serverName,
            transfers: transfers,
            dragOver: dragOver,
            uploadStatus: uploadStatus,
            handleDragOver: handleDragOver,
            handleDragLeave: handleDragLeave,
            handleDrop: handleDrop,
        };
    },
});
export default (await import('vue')).defineComponent({
    setup() {
        return {};
    },
});
; /* PartiallyEnd: #4569/main.vue */
