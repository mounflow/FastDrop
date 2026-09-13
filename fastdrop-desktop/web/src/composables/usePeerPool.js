import { computed, reactive, ref } from 'vue';
import { announceTransfer, completeFile, createTransfer, downloadFileBlob, HttpStatusError, listLocalTransferHistory, listTransfers, triggerBrowserDownload, uploadChunk, } from '../api';
import { useWebSocket } from './useWebSocket';
const PEERS_KEY = 'fastdrop_peer_sessions_v1';
const HISTORY_KEY = 'fastdrop_transfer_history_v1';
const MAX_HISTORY_ROWS = 500;
const CHUNK_SIZE = 4 * 1024 * 1024;
const CHUNK_RETRY_DELAYS = [500, 1000, 2000, 4000, 8000];
class AsyncLimiter {
    maximum;
    active = 0;
    waiters = [];
    constructor(maximum) {
        this.maximum = maximum;
    }
    async run(action) {
        if (this.active < this.maximum) {
            this.active++;
        }
        else {
            await new Promise((resolve) => this.waiters.push(resolve));
        }
        try {
            return await action();
        }
        finally {
            const next = this.waiters.shift();
            if (next)
                next();
            else
                this.active--;
        }
    }
}
export function usePeerPool(handlers = {}) {
    const peers = ref([]);
    const selectedIds = ref([]);
    const runtimes = new Map();
    const httpLimiter = new AsyncLimiter(6);
    const readiness = new Map();
    const resolvedReadiness = new Map();
    const transferControls = new Map();
    const connectedPeers = computed(() => peers.value.filter((peer) => peer.status === 'connected'));
    function persist() {
        const sessions = peers.value.map(({ status: _status, ...session }) => session);
        sessionStorage.setItem(PEERS_KEY, JSON.stringify(sessions));
    }
    function updateStatus(peerId, status) {
        const peer = peers.value.find((item) => item.id === peerId);
        if (peer)
            peer.status = status;
        handlers.onPeerChanged?.();
    }
    function wsUrl(session) {
        if (session.websocketUrl) {
            const parsed = new URL(session.websocketUrl, session.baseUrl);
            // Some servers return a URL containing their configured host. The
            // explicitly paired base URL is the one proven reachable by this PC.
            const base = new URL(session.baseUrl);
            parsed.protocol = base.protocol === 'https:' ? 'wss:' : 'ws:';
            parsed.host = base.host;
            return parsed.toString();
        }
        const base = new URL(session.baseUrl);
        base.protocol = base.protocol === 'https:' ? 'wss:' : 'ws:';
        base.pathname = '/ws/v1';
        base.search = '';
        return base.toString();
    }
    function addPeer(session) {
        removePeer(session.id, false);
        const view = reactive({ ...session, status: 'connecting' });
        peers.value.push(view);
        if (!selectedIds.value.includes(session.id)) {
            selectedIds.value.push(session.id);
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
                    updateStatus(session.id, 'disconnected');
                    handlers.onAuthFailed?.(session.id);
                },
                onMessage: (message) => handleMessage(session.id, message),
            },
        });
        runtimes.set(session.id, { session, ws });
        persist();
        handlers.onPeerChanged?.();
    }
    function removePeer(peerId, shouldPersist = true) {
        runtimes.get(peerId)?.ws.close();
        runtimes.delete(peerId);
        peers.value = peers.value.filter((peer) => peer.id !== peerId);
        selectedIds.value = selectedIds.value.filter((id) => id !== peerId);
        for (const [key, waiter] of readiness) {
            if (key.startsWith(`${peerId}::`)) {
                clearTimeout(waiter.timer);
                waiter.reject(new Error('Device disconnected'));
                readiness.delete(key);
            }
        }
        for (const key of resolvedReadiness.keys()) {
            if (key.startsWith(`${peerId}::`))
                resolvedReadiness.delete(key);
        }
        for (const [key, control] of transferControls) {
            if (key.startsWith(`${peerId}::`)) {
                resumeControl(control);
                transferControls.delete(key);
            }
        }
        if (shouldPersist)
            persist();
        handlers.onPeerChanged?.();
    }
    function restore() {
        try {
            const raw = sessionStorage.getItem(PEERS_KEY);
            if (!raw)
                return;
            const sessions = JSON.parse(raw);
            for (const session of sessions)
                addPeer(session);
        }
        catch {
            sessionStorage.removeItem(PEERS_KEY);
        }
    }
    function close() {
        for (const runtime of runtimes.values())
            runtime.ws.close();
        runtimes.clear();
        for (const waiter of readiness.values()) {
            clearTimeout(waiter.timer);
            waiter.reject(new Error('Peer pool closed'));
        }
        readiness.clear();
        resolvedReadiness.clear();
        for (const control of transferControls.values())
            resumeControl(control);
        transferControls.clear();
    }
    function send(peerId, message) {
        runtimes.get(peerId)?.ws.send(message);
    }
    function pauseTransfer(peerId, transferId) {
        const control = transferControls.get(transferKey(peerId, transferId));
        if (control)
            control.paused = true;
        send(peerId, transferEnvelope('transfer.pause', transferId));
    }
    function resumeTransfer(peerId, transferId) {
        const control = transferControls.get(transferKey(peerId, transferId));
        if (control)
            resumeControl(control);
        send(peerId, transferEnvelope('transfer.resume', transferId));
    }
    function handleMessage(peerId, raw) {
        const message = raw;
        const payload = message.payload ?? {};
        const runtime = runtimes.get(peerId);
        if (runtime?.session.role === 'local-session') {
            if (message.type === 'device.info')
                updateStatus(peerId, 'connected');
            if (message.type === 'device.disconnect')
                updateStatus(peerId, 'disconnected');
        }
        const transferId = (payload.transferId ?? payload.offerId ?? '');
        const accepted = message.type === 'transfer.accepted'
            || message.type === 'file.offer.accept';
        const rejected = message.type === 'transfer.rejected'
            || message.type === 'file.offer.reject';
        if (accepted || rejected) {
            const key = `${peerId}::${transferId}`;
            const waiter = readiness.get(key);
            if (waiter) {
                clearTimeout(waiter.timer);
                readiness.delete(key);
                if (accepted)
                    waiter.resolve();
                else
                    waiter.reject(new Error('Recipient rejected the transfer'));
            }
            else {
                resolvedReadiness.set(key, accepted);
            }
        }
        handlers.onMessage?.(peerId, raw);
    }
    function waitForAcceptance(peerId, transferId) {
        const key = `${peerId}::${transferId}`;
        const resolved = resolvedReadiness.get(key);
        if (resolved !== undefined) {
            resolvedReadiness.delete(key);
            return resolved
                ? Promise.resolve()
                : Promise.reject(new Error('Recipient rejected the transfer'));
        }
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => {
                readiness.delete(key);
                reject(new Error('Timed out waiting for recipient acceptance'));
            }, 120_000);
            readiness.set(key, { resolve, reject, timer });
        });
    }
    async function sendFiles(files, peerIds = selectedIds.value) {
        const onlineIds = new Set(peers.value
            .filter((peer) => peer.status === 'connected')
            .map((peer) => peer.id));
        const targets = peerIds
            .filter((id) => onlineIds.has(id))
            .map((id) => runtimes.get(id))
            .filter((runtime) => runtime !== undefined);
        if (targets.length === 0)
            throw new Error('Select at least one connected device');
        const jobs = targets.flatMap((runtime) => files.map((file) => () => sendFile(runtime, file)));
        await runJobs(jobs, 2);
    }
    async function sendFile(runtime, file) {
        const { session } = runtime;
        const sha256 = await sha256File(file);
        const offerId = crypto.randomUUID();
        const directUpload = session.role === 'remote-server';
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
        }, undefined, session));
        const remoteFile = result.files[0];
        const control = { paused: false };
        const controlKey = transferKey(session.id, result.transferId);
        transferControls.set(controlKey, control);
        try {
            emitProgress(session, result, remoteFile.fileId, file, 0, directUpload && isConfirmationPlatform(session.platform)
                ? 'waiting_accept'
                : 'preparing');
            if (directUpload && isConfirmationPlatform(session.platform)) {
                await waitForAcceptance(session.id, result.transferId);
            }
            await waitWhilePaused(control);
            await uploadFileChunks(session, result, remoteFile.fileId, file, control);
            await waitWhilePaused(control);
            if (directUpload) {
                await httpLimiter.run(() => completeFile(`/api/v1/transfers/${result.transferId}/files/${remoteFile.fileId}/complete`, file.size, sha256, undefined, session));
                emitProgress(session, result, remoteFile.fileId, file, file.size, 'completed');
                return;
            }
            await httpLimiter.run(() => announceTransfer(result.transferId, session));
            emitProgress(session, result, remoteFile.fileId, file, file.size, 'waiting_accept');
        }
        finally {
            resumeControl(control);
            transferControls.delete(controlKey);
        }
    }
    async function uploadFileChunks(session, result, fileId, file, control) {
        const totalChunks = Math.ceil(file.size / CHUNK_SIZE);
        let transferred = 0;
        const jobs = Array.from({ length: totalChunks }, (_, index) => async () => {
            const start = index * CHUNK_SIZE;
            const end = Math.min(start + CHUNK_SIZE, file.size);
            const data = await file.slice(start, end).arrayBuffer();
            await uploadChunkWithRetry(async () => {
                await httpLimiter.run(() => uploadChunk(`/api/v1/transfers/${result.transferId}/files/${fileId}/chunks/${index}`, data, undefined, session));
            }, control);
            transferred += data.byteLength;
            emitProgress(session, result, fileId, file, transferred, control.paused ? 'paused' : 'transferring');
        });
        await runJobs(jobs, 3);
    }
    function emitProgress(session, result, fileId, file, transferredBytes, status, error) {
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
        });
    }
    async function acceptOffer(offer) {
        const runtime = runtimes.get(offer.peerId);
        if (!runtime)
            throw new Error('Peer is no longer connected');
        runtime.ws.send({
            version: 1,
            type: 'file.offer.accept',
            messageId: crypto.randomUUID(),
            timestamp: Date.now(),
            payload: { offerId: offer.offerId },
        });
        for (const file of offer.files) {
            const blob = await httpLimiter.run(() => downloadFileBlob(offer.transferId, file.fileId, undefined, runtime.session));
            triggerBrowserDownload(blob, file.name);
        }
    }
    function rejectOffer(offer) {
        send(offer.peerId, {
            version: 1,
            type: 'file.offer.reject',
            messageId: crypto.randomUUID(),
            timestamp: Date.now(),
            payload: { offerId: offer.offerId, reason: 'user_rejected' },
        });
    }
    async function loadHistory() {
        const peerRows = await Promise.all(peers.value.map(async (peer) => {
            try {
                const history = await listTransfers(peer);
                return history.map((row) => ({
                    ...row,
                    peerId: peer.id,
                    peerName: peer.name,
                    peerRole: peer.role,
                }));
            }
            catch {
                return [];
            }
        }));
        const localRows = await listLocalTransferHistory()
            .then((history) => history.map((row) => ({
            ...row,
            peerId: row.peerDeviceId,
            peerName: row.peerName || 'Unknown Device',
            peerRole: 'local-session',
        })))
            .catch(() => []);
        // Keep a token-free local projection so remote-server transfers remain
        // visible when that phone is offline or has restarted its in-memory server.
        const merged = new Map();
        for (const row of readCachedHistory())
            merged.set(row.id, row);
        for (const row of localRows)
            merged.set(row.id, row);
        for (const row of peerRows.flat())
            merged.set(row.id, row);
        const rows = [...merged.values()]
            .sort((a, b) => b.createdAt - a.createdAt)
            .slice(0, MAX_HISTORY_ROWS);
        persistHistory(rows);
        return rows;
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
        pauseTransfer,
        resumeTransfer,
        acceptOffer,
        rejectOffer,
        loadHistory,
    };
}
function readCachedHistory() {
    try {
        const raw = localStorage.getItem(HISTORY_KEY);
        if (!raw)
            return [];
        const rows = JSON.parse(raw);
        return Array.isArray(rows) ? rows : [];
    }
    catch {
        try {
            localStorage.removeItem(HISTORY_KEY);
        }
        catch {
            // Storage can be unavailable in hardened WebView profiles.
        }
        return [];
    }
}
function persistHistory(rows) {
    try {
        localStorage.setItem(HISTORY_KEY, JSON.stringify(rows));
    }
    catch {
        // History caching is best effort; the durable local SQLite rows still load.
    }
}
function transferKey(peerId, transferId) {
    return `${peerId}::${transferId}`;
}
function transferEnvelope(type, transferId) {
    return {
        version: 1,
        type,
        messageId: crypto.randomUUID(),
        timestamp: Date.now(),
        payload: { transferId },
    };
}
function resumeControl(control) {
    control.paused = false;
    control.resume?.();
    control.resume = undefined;
    control.resumePromise = undefined;
}
async function waitWhilePaused(control) {
    while (control.paused) {
        if (!control.resumePromise) {
            control.resumePromise = new Promise((resolve) => {
                control.resume = resolve;
            });
        }
        await control.resumePromise;
    }
}
async function uploadChunkWithRetry(action, control) {
    for (let attempt = 0;; attempt++) {
        await waitWhilePaused(control);
        try {
            await action();
            return;
        }
        catch (error) {
            if (attempt >= CHUNK_RETRY_DELAYS.length || !isRetryableChunkError(error)) {
                throw error;
            }
            await delay(CHUNK_RETRY_DELAYS[attempt]);
        }
    }
}
function isRetryableChunkError(error) {
    if (error instanceof DOMException && error.name === 'AbortError')
        return false;
    if (error instanceof HttpStatusError) {
        return error.status === 408 || error.status === 429 || error.status >= 500;
    }
    // Chunk PUT is idempotent by transfer/file/index, so transport failures are
    // safe to replay after the required exponential backoff.
    return true;
}
function delay(milliseconds) {
    return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
function isConfirmationPlatform(platform) {
    return ['android', 'ios', 'macos'].includes(platform.toLowerCase());
}
async function sha256File(file) {
    const digest = await crypto.subtle.digest('SHA-256', await file.arrayBuffer());
    return Array.from(new Uint8Array(digest))
        .map((byte) => byte.toString(16).padStart(2, '0'))
        .join('');
}
async function runJobs(jobs, concurrency) {
    let next = 0;
    const workers = Array.from({ length: Math.min(concurrency, jobs.length) }, async () => {
        while (next < jobs.length) {
            const job = jobs[next++];
            await job();
        }
    });
    await Promise.all(workers);
}
