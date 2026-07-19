let cachedSession = null;
export function setSession(s) {
    cachedSession = s;
}
function authHeaders() {
    if (!cachedSession)
        return {};
    return {
        Authorization: `Bearer ${cachedSession.accessToken}`,
        'X-Session-Id': cachedSession.sessionId,
    };
}
async function asJson(resp) {
    if (!resp.ok) {
        const err = await resp.json().catch(() => ({ error: { code: 'INTERNAL_ERROR', message: resp.statusText } }));
        throw new Error(err.error?.code || 'INTERNAL_ERROR');
    }
    return resp.json();
}
export async function fetchQR() {
    return asJson(await fetch('/api/v1/pair/qr'));
}
export async function refreshPairToken(pairId) {
    return asJson(await fetch('/api/v1/pair/token/refresh', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...authHeaders() },
        body: JSON.stringify({ pairId }),
    }));
}
export async function pollPairStatus(requestId) {
    return asJson(await fetch(`/api/v1/pair/requests/${requestId}`));
}
export async function acceptPair(requestId) {
    await fetch(`/api/v1/pair/requests/${requestId}/accept`, {
        method: 'POST',
        ...{ headers: authHeaders() },
    });
}
export async function rejectPair(requestId) {
    await fetch(`/api/v1/pair/requests/${requestId}/reject`, {
        method: 'POST',
        ...{ headers: authHeaders() },
    });
}
export async function listTransfers() {
    const data = await asJson(await fetch('/api/v1/transfers', { headers: authHeaders() }));
    return data.transfers || [];
}
export async function createTransfer(body) {
    return asJson(await fetch('/api/v1/transfers', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...authHeaders() },
        body: JSON.stringify(body),
    }));
}
export async function uploadChunk(url, data) {
    const resp = await fetch(url, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/octet-stream', ...authHeaders() },
        body: data,
    });
    if (!resp.ok)
        throw new Error(`chunk upload failed: ${resp.status}`);
}
export async function completeFile(url, size, sha256) {
    return asJson(await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...authHeaders() },
        body: JSON.stringify({ size, sha256 }),
    }));
}
export async function cancelTransfer(transferId) {
    await fetch(`/api/v1/transfers/${transferId}/cancel`, { method: 'POST', headers: authHeaders() });
}
