const SESSION_KEY = 'fastdrop_session';
function localUrl(path) {
    if (location.protocol === 'http:' || location.protocol === 'https:')
        return path;
    return `http://127.0.0.1:9527${path}`;
}
let cachedSession = null;
export function setSession(s) {
    cachedSession = s;
    if (s) {
        sessionStorage.setItem(SESSION_KEY, JSON.stringify(s));
    }
    else {
        sessionStorage.removeItem(SESSION_KEY);
    }
}
/// Restore session from sessionStorage (survives page refresh, cleared on tab close).
export function restoreSession() {
    try {
        const raw = sessionStorage.getItem(SESSION_KEY);
        if (!raw)
            return null;
        const s = JSON.parse(raw);
        if (s && s.sessionId && s.accessToken) {
            cachedSession = s;
            return s;
        }
    }
    catch { /* ignore */ }
    return null;
}
function authHeaders(target) {
    const session = target ?? cachedSession;
    if (!session)
        return {};
    return {
        Authorization: `Bearer ${session.accessToken}`,
        'X-Session-Id': session.sessionId,
    };
}
function targetUrl(path, target) {
    if (!target?.baseUrl)
        return localUrl(path);
    return `${target.baseUrl.replace(/\/$/, '')}${path}`;
}
async function asJson(resp) {
    if (!resp.ok) {
        const err = await resp.json().catch(() => ({ error: { code: 'INTERNAL_ERROR', message: resp.statusText } }));
        throw new Error(err.error?.code || 'INTERNAL_ERROR');
    }
    return resp.json();
}
export async function fetchQR() {
    return asJson(await fetch(localUrl('/api/v1/pair/qr')));
}
export async function refreshPairToken(pairId) {
    return asJson(await fetch(localUrl('/api/v1/pair/token/refresh'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...authHeaders() },
        body: JSON.stringify({ pairId }),
    }));
}
export async function pollPairStatus(requestId, baseUrl) {
    return asJson(await fetch(`${baseUrl?.replace(/\/$/, '') ?? ''}/api/v1/pair/requests/${requestId}`));
}
export async function acceptPair(requestId) {
    return asJson(await fetch(localUrl(`/api/v1/pair/requests/${requestId}/accept`), {
        method: 'POST',
    }));
}
export async function rejectPair(requestId) {
    await fetch(localUrl(`/api/v1/pair/requests/${requestId}/reject`), {
        method: 'POST',
        ...{ headers: authHeaders() },
    });
}
export async function listPairRequests() {
    const data = await asJson(await fetch(localUrl('/api/v1/pair/requests')));
    return {
        requests: (data.requests || []).map((request) => ({
            requestId: request.requestId,
            deviceId: request.deviceId || request.device?.deviceId || request.requestId,
            deviceName: request.deviceName || request.device?.deviceName || 'Unknown Device',
            platform: request.platform || request.device?.platform || 'unknown',
            status: request.status,
            createdAt: request.createdAt,
        })),
    };
}
export async function listTransfers(target) {
    const data = await asJson(await fetch(targetUrl('/api/v1/transfers', target), { headers: authHeaders(target) }));
    return data.transfers || [];
}
/// Revoke the current session (DELETE /api/v1/session). Server then
/// broadcasts session.revoked, which the Vue side already handles by
/// clearing state and falling back to the QR pairing page. Used by
/// the "重新配对" button when the user wants to pair a different
/// phone or recovery from a stale session.
export async function revokeSession() {
    await fetch(localUrl('/api/v1/session'), {
        method: 'DELETE',
        headers: authHeaders(),
    });
}
export async function getTransfer(transferId, target) {
    return asJson(await fetch(targetUrl(`/api/v1/transfers/${transferId}`, target), { headers: authHeaders(target) }));
}
export async function createTransfer(body, signal, target) {
    return asJson(await fetch(targetUrl('/api/v1/transfers', target), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...authHeaders(target) },
        body: JSON.stringify(body),
        signal,
    }));
}
export async function uploadChunk(url, data, signal, target) {
    const resp = await fetch(url.startsWith('http') ? url : targetUrl(url, target), {
        method: 'PUT',
        headers: { 'Content-Type': 'application/octet-stream', ...authHeaders(target) },
        body: data,
        signal,
    });
    if (!resp.ok)
        throw new Error(`chunk upload failed: ${resp.status}`);
}
export async function completeFile(url, size, sha256, signal, target) {
    return asJson(await fetch(url.startsWith('http') ? url : targetUrl(url, target), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...authHeaders(target) },
        body: JSON.stringify({ size, sha256 }),
        signal,
    }));
}
export async function cancelTransfer(transferId, target) {
    await fetch(targetUrl(`/api/v1/transfers/${transferId}/cancel`, target), { method: 'POST', headers: authHeaders(target) });
}
export async function announceTransfer(transferId, target) {
    const response = await fetch(targetUrl(`/api/v1/transfers/${transferId}/offer`, target), {
        method: 'POST',
        headers: authHeaders(target),
    });
    if (!response.ok)
        throw new Error(`offer failed: ${response.status}`);
}
export async function getSettings() {
    return asJson(await fetch(localUrl('/api/v1/settings')));
}
export async function updateSettings(body) {
    return asJson(await fetch(localUrl('/api/v1/settings'), {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
    }));
}
/// Download a file's content as a Blob (full GET, no Range).
export async function downloadFileBlob(transferId, fileId, signal, target) {
    const resp = await fetch(targetUrl(`/api/v1/transfers/${transferId}/files/${fileId}/content`, target), {
        headers: authHeaders(target),
        signal,
    });
    if (!resp.ok)
        throw new Error(`download failed: ${resp.status}`);
    return resp.blob();
}
export async function getServerInfo(baseUrl = '') {
    const root = baseUrl.replace(/\/$/, '');
    const response = await fetch(`${root}/api/v1/server/info`);
    if (response.ok)
        return asJson(response);
    const health = await asJson(await fetch(`${root}/api/v1/health`));
    return {
        deviceId: health.deviceId || `${health.deviceName || 'peer'}@${root}`,
        name: health.deviceName || 'FastDrop Device',
        platform: health.platform || 'unknown',
        protocol: health.protocol || 1,
        port: Number(new URL(root || location.origin).port || 9527),
    };
}
export async function requestDiscoverPair(baseUrl, device) {
    return asJson(await fetch(`${baseUrl.replace(/\/$/, '')}/api/v1/pair/discover`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ device }),
    }));
}
/// Trigger a browser file-save dialog for the given Blob.
export function triggerBrowserDownload(blob, fileName) {
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = fileName;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
}
