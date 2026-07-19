# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Status

This repo is in the **design phase**. The only artifact is `FastDrop_局域网文件快传App_详细开发设计.md` — the full product spec. No source code exists yet. When starting implementation, treat that document as the source of truth for protocol, architecture, and conventions; do not contradict it without explicit approval.

FastDrop is a **LAN-only** file transfer app (Android ↔ Windows). No cloud, no accounts, no login. Phone scans a QR code to pair with the PC over the local network.

## Platform & Shell

Runs on **Windows**. Use Windows PowerShell / CMD-compatible syntax for any system commands — do not use Linux/Bash-only constructs.

## Tech Stack (locked by the spec)

- **Android client:** Flutter (state management: Riverpod or Bloc — never `setState` alone for transfer state)
- **Windows core service:** Go (single binary, embeds Vue build via `//go:embed web/dist/*`)
- **Windows UI:** Vue 3 + TypeScript (built with Vite)
- **DB:** SQLite
- **Control channel:** WebSocket  ·  **File channel:** HTTP
- **Phase-1 discovery:** QR code  ·  **Phase-2:** mDNS (`_fastdrop._tcp.local`)

## Target Directory Layout

When scaffolding, follow the layout in the spec (§24, §25):

- Go: `fastdrop-desktop/cmd/fastdrop/`, `internal/{api,websocket,pairing,session,transfer,storage,discovery,database,config,security}/`, `web/`, `migrations/`
- Flutter: `lib/{app,core,features,shared}/` with feature folders under `features/`
- **Keep `internal/discovery/` from Phase 1** — it's reserved for Phase-2 mDNS.

## Critical Protocol Constants (do not deviate)

- **Chunk size: 4 MB** (4194304 bytes) for all of Phase 1
- **Pair token: 32 bytes** from `crypto/rand`, Base64URL-encoded, **60-second TTL, single-use, invalidates after 5 failures** — never use `math/rand`, timestamps, or auto-increment IDs
- **Session TTL: 12 hours**; all sessions invalidate on server restart
- **Concurrency: 3 chunks per file, 2 files concurrent, 6 max global HTTP requests** — do not raise these
- **Chunk retry: max 5 attempts** with exponential backoff (500ms, 1s, 2s, 4s, 8s)
- **Heartbeat: 15s ping, 3 missed pongs = disconnected, 60s reconnect grace**
- **Progress push cadence:** WebSocket ≤ every 200–500ms, DB flush every 1–2s, UI ~200ms

## Security Boundaries (these are product requirements, not suggestions)

- **Filename sanitization is mandatory** — strip `../`, `..\`, Windows-illegal chars (`\/:*?"<>|`), NUL, and Windows reserved names (`CON`, `PRN`, `AUX`, `NUL`, `COM1-9`, `LPT1-9`). Only ever use the basename.
- **Token storage:** never store pair tokens or session tokens in plaintext — hash them in the DB (`sessions.token_hash`).
- **Never log:** full tokens, raw QR content, file contents, full sensitive paths. Mask `sessionId` in logs.
- **Temp files:** `downloads/.fastdrop-temp/{transferId}/{fileId}.part` — atomic rename to final path only after SHA-256 verification passes.
- **Rename-on-conflict policy:** `photo.jpg` → `photo (1).jpg`. Never overwrite by default.
- **CORS:** no `Access-Control-Allow-Origin: *` on authenticated endpoints.
- **Request size limits:** pair request ≤ 64 KB, JSON ≤ 1 MB, chunk upload = `chunkSize + small overhead`.
- **QR code JSON must never contain:** permanent password, session token, file paths, or PII.

## Two-Channel Design (why)

WebSocket = control (auth, pair, offers, progress, cancel, heartbeat). HTTP = file data (chunk PUT, Range download, completion). **Keep these separate** — the spec's rationale is that big file transfers must never block control messages, and HTTP gives free resumable/range semantics.

## File Transfer State Machine

Canonical states (§12): `created → waiting_accept → preparing → transferring ⇄ paused → verifying → completed`, with branches to `rejected`, `cancelled`, `failed` (→ `retrying` → `transferring`). Any state-transition code must match this set exactly.

## Task Hierarchy

`Offer` → `Transfer Batch` → `File Task` → `Chunk`. Upload via `PUT /api/v1/transfers/{transferId}/files/{fileId}/chunks/{chunkIndex}` (write at offset `chunkIndex × chunkSize` using `file.WriteAt`). Download via `GET .../content` with `Range`. Complete via `POST .../complete` returning `{size, sha256}`.

## REST & WS Contract

All endpoints are prefixed `/api/v1/`. WebSocket path: `ws://host:9527/ws/v1`. Auth on protected routes requires both `Authorization: Bearer <sessionToken>` and `X-Session-Id: <sessionId>`. WS auth: prefer headers; fall back to a first-message `{type:"auth",...}` — and until that auth succeeds, no other message types may be processed. Full route list and message-type catalog are in §20 and §8 of the spec — consult them before adding endpoints.

## Error Model

All errors use `{error: {code, message, requestId, details}}`. The error-code vocabulary (§21: `PAIR_TOKEN_*`, `SESSION_*`, `FILE_HASH_MISMATCH`, `INSUFFICIENT_STORAGE`, etc.) is the closed set — reuse codes, don't invent synonyms.

## DB Schema

Five tables defined in §22: `devices`, `sessions`, `transfers`, `transfer_files`, `file_chunk_states`. Chunk completion is a **bitmap BLOB**, not a per-chunk row — don't accidentally "normalize" this.

## Phase Boundaries

- **Phase 1 = QR only.** mDNS code may be scaffolded but must not be wired into the active discovery flow.
- **Phase 2 = mDNS discovery + manual IP fallback.** Discovery layer must remain behind an interface (`DiscoveryPublisher` in Go, `DeviceDiscovery` in Flutter) with `QrDiscovery` / `MdnsDiscovery` / `ManualDiscovery` implementations.
- Explicitly **out of scope** (both phases): iOS, macOS, Linux, public-internet transit, WebRTC, cloud storage, user accounts, folder incremental sync.

## Before Implementing

When beginning any milestone, re-read the relevant section of the spec (§35 has the 6-milestone Phase-1 breakdown) and follow its ordering. The spec is the contract; this file is a fast-index into it.
