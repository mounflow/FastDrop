// Minimal WS client wrapper. Reconnects with a 60-second grace window (§19).
import { ref, type Ref } from 'vue'

export type WSStatus = 'disconnected' | 'connecting' | 'connected'

export interface WSHandlers {
  onOpen?: () => void
  onMessage?: (msg: unknown) => void
  onClose?: () => void
  onError?: (err: unknown) => void
}

export interface UseWebSocketOptions {
  url: string
  sessionId: string
  accessToken: string
  handlers: WSHandlers
}

export function useWebSocket(opts: UseWebSocketOptions): {
  status: Ref<WSStatus>
  send: (msg: unknown) => void
  close: () => void
} {
  const status = ref<WSStatus>('disconnected')
  let ws: WebSocket | null = null
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null
  let firstConnectAt = Date.now()

  function connect() {
    status.value = 'connecting'
    const url = `${opts.url}?sessionId=${encodeURIComponent(opts.sessionId)}`
    ws = new WebSocket(url)
    ws.onopen = () => {
      status.value = 'connected'
      // Send the first auth message even though we passed headers — fallback.
      ws?.send(JSON.stringify({
        version: 1,
        type: 'auth',
        messageId: crypto.randomUUID(),
        timestamp: Date.now(),
        payload: { sessionId: opts.sessionId, accessToken: opts.accessToken },
      }))
      opts.handlers.onOpen?.()
    }
    ws.onmessage = (ev) => {
      try {
        opts.handlers.onMessage?.(JSON.parse(ev.data))
      } catch {
        // ignore malformed frames
      }
    }
    ws.onclose = () => {
      status.value = 'disconnected'
      opts.handlers.onClose?.()
      scheduleReconnect()
    }
    ws.onerror = (err) => {
      opts.handlers.onError?.(err)
    }
  }

  function scheduleReconnect() {
    if (Date.now() - firstConnectAt > 60_000) {
      // Past the 60s grace window; give up.
      return
    }
    if (reconnectTimer) clearTimeout(reconnectTimer)
    reconnectTimer = setTimeout(connect, 1000)
  }

  function send(msg: unknown) {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(msg))
    }
  }

  function close() {
    if (reconnectTimer) clearTimeout(reconnectTimer)
    ws?.close()
    ws = null
    status.value = 'disconnected'
  }

  connect()

  return { status, send, close }
}
