// Minimal WS client wrapper. Reconnects with a 60-second grace window (§19).
// Sends heartbeat.ping every 15s; 3 missed pongs = disconnected (§19).
import { ref } from 'vue';
const HEARTBEAT_INTERVAL = 15_000; // §19: 15s ping
const MAX_MISSED_PONGS = 3; // §19: 3 missed = disconnected
const GRACE_WINDOW = 60_000; // §19: 60s reconnect grace
const BACKOFF_BASE = 1_000; // 1s initial backoff
const BACKOFF_MAX = 15_000; // cap at 15s
export function useWebSocket(opts) {
    const status = ref('disconnected');
    let ws = null;
    let reconnectTimer = null;
    let heartbeatTimer = null;
    let missedPongs = 0;
    let disconnectedAt = null;
    let reconnectAttempts = 0;
    let authFailed = false;
    function startHeartbeat() {
        stopHeartbeat();
        missedPongs = 0;
        heartbeatTimer = setInterval(() => {
            if (!ws || ws.readyState !== WebSocket.OPEN)
                return;
            missedPongs++;
            if (missedPongs > MAX_MISSED_PONGS) {
                // Server unresponsive — tear down and let reconnect logic handle it.
                ws?.close();
                return;
            }
            ws.send(JSON.stringify({
                version: 1,
                type: 'heartbeat.ping',
                timestamp: Date.now(),
            }));
        }, HEARTBEAT_INTERVAL);
    }
    function stopHeartbeat() {
        if (heartbeatTimer) {
            clearInterval(heartbeatTimer);
            heartbeatTimer = null;
        }
    }
    function connect() {
        status.value = reconnectAttempts > 0 ? 'reconnecting' : 'connecting';
        ws = new WebSocket(opts.url);
        ws.onopen = () => {
            // Send auth as the first message; wait for auth.result before
            // marking the connection as established.
            ws?.send(JSON.stringify({
                version: 1,
                type: 'auth',
                messageId: crypto.randomUUID(),
                timestamp: Date.now(),
                payload: { sessionId: opts.sessionId, accessToken: opts.accessToken },
            }));
        };
        ws.onmessage = (ev) => {
            try {
                const msg = JSON.parse(ev.data);
                // Handle auth result before forwarding to business logic.
                if (msg?.type === 'auth.result') {
                    if (msg.payload?.ok) {
                        status.value = 'connected';
                        disconnectedAt = null;
                        reconnectAttempts = 0;
                        startHeartbeat();
                        opts.handlers.onOpen?.();
                    }
                    else {
                        // Auth rejected — close and do not reconnect.
                        authFailed = true;
                        opts.handlers.onAuthFailed?.();
                        ws?.close();
                    }
                    return;
                }
                // Intercept heartbeat pong — reset miss counter, don't forward.
                if (msg?.type === 'heartbeat.pong') {
                    missedPongs = 0;
                    return;
                }
                opts.handlers.onMessage?.(msg);
            }
            catch {
                // ignore malformed frames
            }
        };
        ws.onclose = () => {
            status.value = 'disconnected';
            stopHeartbeat();
            opts.handlers.onClose?.();
            if (authFailed)
                return; // session revoked — do not reconnect
            if (disconnectedAt === null)
                disconnectedAt = Date.now();
            scheduleReconnect();
        };
        ws.onerror = (err) => {
            opts.handlers.onError?.(err);
        };
    }
    function scheduleReconnect() {
        // 60-second grace window measured from the moment of disconnect.
        if (disconnectedAt !== null && Date.now() - disconnectedAt > GRACE_WINDOW) {
            return;
        }
        if (reconnectTimer)
            clearTimeout(reconnectTimer);
        // Exponential backoff: 1s, 2s, 4s, 8s, capped at 15s.
        const delay = Math.min(BACKOFF_BASE * Math.pow(2, reconnectAttempts), BACKOFF_MAX);
        reconnectAttempts++;
        reconnectTimer = setTimeout(connect, delay);
    }
    function send(msg) {
        if (ws && ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify(msg));
        }
    }
    function close() {
        if (reconnectTimer)
            clearTimeout(reconnectTimer);
        stopHeartbeat();
        disconnectedAt = null; // prevent reconnect on intentional close
        ws?.close();
        ws = null;
        status.value = 'disconnected';
    }
    connect();
    return { status, send, close };
}
