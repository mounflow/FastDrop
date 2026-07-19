# 手机与电脑局域网文件快传 App
## 详细开发设计方案

---

## 1. 项目定位

### 1.1 产品目标

开发一套手机与电脑之间的局域网文件传输工具，重点解决：

- 不需要账号登录
- 不经过云服务器
- 不需要数据线
- 同一局域网内直接传输
- 手机扫码即可连接电脑
- 支持大文件和多文件
- 后续支持自动发现附近设备

产品核心原则：

> 文件数据不经过云服务器，设备发现、认证和文件传输全部在局域网内完成。

### 1.2 首发平台

建议首发平台：

- 手机端：Android
- 电脑端：Windows

### 1.3 推荐技术栈

- 手机端：Flutter
- 电脑核心服务：Go
- 电脑界面：Vue 3 + TypeScript
- 本地数据库：SQLite
- 控制通道：WebSocket
- 文件通道：HTTP
- 第一阶段设备发现：二维码
- 第二阶段设备发现：mDNS / DNS-SD

第一阶段暂不考虑：

- iOS
- macOS
- Linux
- 公网传输
- WebRTC
- 云存储
- 用户账号
- 文件夹增量同步

---

## 2. 分阶段开发目标

### 2.1 第一阶段

实现：

- 二维码配对
- 一次性 Token 认证
- 局域网直连传输
- 手机向电脑发送文件
- 电脑向手机发送文件
- 多文件任务队列
- 大文件分块传输
- 传输进度
- 取消与失败重试
- SHA-256 完整性校验
- 文件重名处理
- Windows 接收目录设置
- 基础传输历史记录

### 2.2 第二阶段

实现：

- mDNS 自动发现
- 自动列出附近设备
- 点击设备发起配对
- 多网卡地址去重
- 保留二维码连接
- 增加手动输入 IP 的兜底方式

推荐连接优先级：

```text
mDNS 自动发现
      ↓
二维码配对
      ↓
手动输入 IP
```

---

## 3. 总体架构

```text
┌─────────────────────────────────┐
│          Android App            │
│                                 │
│  扫码模块                       │
│  设备连接模块                   │
│  文件选择模块                   │
│  传输任务管理                   │
│  HTTP 文件传输                  │
│  WebSocket 控制通道             │
│  本地任务数据库                 │
└──────────────┬──────────────────┘
               │
               │ 局域网
               │
┌──────────────▼──────────────────┐
│       Windows 本地服务          │
│                                 │
│  HTTP Server                    │
│  WebSocket Server               │
│  一次性 Token 管理              │
│  配对与设备认证                 │
│  文件接收与发送                 │
│  任务管理                       │
│  SHA-256 校验                   │
│  SQLite                         │
│  mDNS 服务发布（第二阶段）      │
└──────────────┬──────────────────┘
               │
┌──────────────▼──────────────────┐
│      Windows 桌面/Web UI        │
│                                 │
│  二维码展示                     │
│  设备确认                       │
│  文件拖拽                       │
│  传输进度                       │
│  接收目录设置                   │
│  历史记录                       │
└─────────────────────────────────┘
```

---

## 4. 通信设计

### 4.1 WebSocket 负责控制消息

WebSocket 用于：

- 设备认证
- 配对确认
- 文件发送请求
- 用户接受或拒绝
- 传输状态变化
- 传输进度通知
- 取消任务
- 心跳检测
- Session 撤销

### 4.2 HTTP 负责文件数据

HTTP 用于：

- 上传文件分块
- 下载文件分块
- 查询已完成分块
- 获取文件元数据
- 完成文件传输
- 文件校验
- HTTP Range 下载

### 4.3 设计原因

控制和数据分离后：

- 大文件不会阻塞控制消息
- 更容易实现断点续传
- 更容易做分块重试
- 可以使用成熟的 HTTP 客户端
- 容易限制并发数
- 更容易监控和调试

---

## 5. 二维码配对设计

### 5.1 二维码内容

推荐二维码使用 JSON：

```json
{
  "version": 1,
  "protocol": "fastdrop",
  "host": "192.168.1.10",
  "port": 9527,
  "pairId": "c366fd40-219c-4be5-b82e-9ab4a6815aaa",
  "token": "URL_SAFE_RANDOM_TOKEN",
  "expiresAt": 1784436000,
  "serverName": "Fang-PC"
}
```

字段说明：

| 字段 | 说明 |
|---|---|
| version | 二维码协议版本 |
| protocol | 自定义协议标识 |
| host | 电脑局域网 IP |
| port | 本地服务端口 |
| pairId | 本次配对唯一编号 |
| token | 一次性配对 Token |
| expiresAt | Token 过期时间 |
| serverName | 电脑名称 |

二维码不要包含：

- 永久密码
- Session Token
- 用户文件路径
- 用户隐私数据

### 5.2 一次性 Token 规则

推荐规则：

- 随机强度至少 128 bit
- 推荐使用 32 字节安全随机数
- 使用 Base64URL 编码
- 默认有效期 60 秒
- 只能成功使用一次
- 成功配对后立即失效
- 连续失败 5 次后失效
- 使用 `crypto/rand`
- 禁止使用时间戳、自增 ID、`math/rand`

Go 示例：

```go
tokenBytes := make([]byte, 32)

if _, err := rand.Read(tokenBytes); err != nil {
    return err
}

token := base64.RawURLEncoding.EncodeToString(tokenBytes)
```

---

## 6. 配对流程

```text
电脑启动本地服务
        │
        ▼
生成 pairId 和一次性 Token
        │
        ▼
电脑显示二维码
        │
        ▼
手机扫描二维码
        │
        ▼
手机检查协议版本和过期时间
        │
        ▼
POST /api/v1/pair/request
        │
        ▼
电脑验证 pairId、Token、来源 IP
        │
        ▼
电脑弹出连接确认
        │
        ├── 拒绝 ──> rejected
        │
        └── 接受
              │
              ▼
        创建 Session
              │
              ▼
        返回 sessionToken
              │
              ▼
        手机建立 WebSocket
```

### 6.1 配对请求

```http
POST /api/v1/pair/request
Content-Type: application/json
```

```json
{
  "pairId": "c366fd40-219c-4be5-b82e-9ab4a6815aaa",
  "token": "URL_SAFE_RANDOM_TOKEN",
  "device": {
    "deviceId": "android-local-generated-uuid",
    "deviceName": "Fang 的手机",
    "platform": "android",
    "appVersion": "0.1.0"
  }
}
```

响应：

```json
{
  "requestId": "pair-request-uuid",
  "status": "waiting_confirmation",
  "expiresIn": 30
}
```

### 6.2 查询配对结果

```http
GET /api/v1/pair/requests/{requestId}
```

接受响应：

```json
{
  "status": "accepted",
  "session": {
    "sessionId": "session-uuid",
    "accessToken": "SESSION_ACCESS_TOKEN",
    "expiresIn": 43200,
    "websocketUrl": "ws://192.168.1.10:9527/ws/v1"
  },
  "server": {
    "deviceId": "windows-device-uuid",
    "deviceName": "Fang-PC",
    "platform": "windows"
  }
}
```

拒绝响应：

```json
{
  "status": "rejected",
  "reason": "user_rejected"
}
```

超时响应：

```json
{
  "status": "expired"
}
```

---

## 7. Session 认证设计

### 7.1 Session 内容

配对成功后创建：

```text
sessionId
accessToken
issuedAt
expiresAt
clientDeviceId
clientIp
permissions
```

建议第一阶段 Session 有效期：

```text
12 小时
```

电脑服务重启后，可以让所有 Session 失效。

### 7.2 HTTP 认证

所有受保护接口必须携带：

```http
Authorization: Bearer SESSION_ACCESS_TOKEN
X-Session-Id: session-uuid
```

服务端检查：

- Token 是否存在
- Token 是否过期
- Session 是否被撤销
- Session ID 是否匹配
- 设备 ID 是否匹配
- 来源 IP 是否异常变化

### 7.3 WebSocket 认证

优先使用请求头：

```http
Authorization: Bearer SESSION_ACCESS_TOKEN
```

不方便设置请求头时，连接后第一条消息认证：

```json
{
  "type": "auth",
  "requestId": "uuid",
  "payload": {
    "sessionId": "session-uuid",
    "accessToken": "SESSION_ACCESS_TOKEN"
  }
}
```

认证成功前禁止处理其他业务消息。

---

## 8. WebSocket 控制协议

### 8.1 通用消息结构

```json
{
  "version": 1,
  "type": "file.offer",
  "messageId": "message-uuid",
  "requestId": "request-uuid",
  "timestamp": 1784436000123,
  "payload": {}
}
```

### 8.2 主要消息类型

```text
auth
auth.result

heartbeat.ping
heartbeat.pong

device.info
device.disconnect

file.offer
file.offer.accept
file.offer.reject

transfer.created
transfer.started
transfer.progress
transfer.paused
transfer.cancel
transfer.cancelled
transfer.failed
transfer.completed

session.revoked
error
```

### 8.3 文件发送请求

```json
{
  "version": 1,
  "type": "file.offer",
  "messageId": "msg-001",
  "timestamp": 1784436000123,
  "payload": {
    "offerId": "offer-uuid",
    "files": [
      {
        "clientFileId": "local-file-001",
        "name": "video.mp4",
        "size": 1073741824,
        "mimeType": "video/mp4",
        "modifiedAt": 1784430000000
      }
    ]
  }
}
```

接受：

```json
{
  "type": "file.offer.accept",
  "payload": {
    "offerId": "offer-uuid"
  }
}
```

拒绝：

```json
{
  "type": "file.offer.reject",
  "payload": {
    "offerId": "offer-uuid",
    "reason": "user_rejected"
  }
}
```

默认策略：

```text
每次接收文件时都询问用户
```

---

## 9. 文件传输模型

任务层级：

```text
Offer
└── Transfer Batch
    ├── File Task 1
    │   ├── Chunk 0
    │   ├── Chunk 1
    │   └── Chunk N
    └── File Task 2
```

- Offer：一次发送请求
- Transfer Batch：一次批量任务
- File Task：单个文件任务
- Chunk：文件分块

### 9.1 分块大小

第一阶段统一使用：

```text
4 MB
```

未来可动态调整：

| 文件大小 | 分块大小 |
|---:|---:|
| 小于 16 MB | 1 MB |
| 16 MB～1 GB | 4 MB |
| 1 GB～10 GB | 8 MB |
| 大于 10 GB | 16 MB |

---

## 10. 手机向电脑上传文件

### 10.1 创建传输任务

```http
POST /api/v1/transfers
Authorization: Bearer xxx
```

```json
{
  "offerId": "offer-uuid",
  "direction": "client_to_server",
  "files": [
    {
      "clientFileId": "local-file-001",
      "name": "video.mp4",
      "size": 1073741824,
      "mimeType": "video/mp4",
      "chunkSize": 4194304,
      "sha256": null
    }
  ]
}
```

响应：

```json
{
  "transferId": "transfer-uuid",
  "files": [
    {
      "fileId": "server-file-uuid",
      "clientFileId": "local-file-001",
      "chunkSize": 4194304,
      "totalChunks": 256,
      "uploadUrlTemplate": "/api/v1/transfers/transfer-uuid/files/server-file-uuid/chunks/{index}"
    }
  ]
}
```

### 10.2 上传分块

```http
PUT /api/v1/transfers/{transferId}/files/{fileId}/chunks/{chunkIndex}
Authorization: Bearer xxx
Content-Type: application/octet-stream
Content-Length: 4194304
X-Chunk-SHA256: optional-chunk-hash
```

服务端临时文件：

```text
downloads/.fastdrop-temp/{transferId}/{fileId}.part
```

写入偏移：

```text
offset = chunkIndex × chunkSize
```

Go 中建议：

```go
file.WriteAt(data, offset)
```

### 10.3 查询分块状态

```http
GET /api/v1/transfers/{transferId}/files/{fileId}/chunks
```

```json
{
  "completedChunks": [0, 1, 2, 3, 5, 6],
  "missingChunks": [4, 7, 8, 9]
}
```

### 10.4 完成上传

```http
POST /api/v1/transfers/{transferId}/files/{fileId}/complete
```

```json
{
  "size": 1073741824,
  "sha256": "full-file-sha256"
}
```

服务端处理顺序：

1. 检查全部分块
2. 检查文件大小
3. 计算 SHA-256
4. 比较发送方哈希
5. 处理文件重名
6. 原子移动到目标目录
7. 更新数据库
8. 推送完成事件

---

## 11. 电脑向手机下载文件

电脑通过 WebSocket 发出 `file.offer`。

手机接受后请求：

```http
GET /api/v1/transfers/{transferId}/files/{fileId}/content
Range: bytes=0-4194303
```

服务端返回：

```http
HTTP/1.1 206 Partial Content
Content-Range: bytes 0-4194303/524288000
```

Android 文件保存建议：

- 图片和视频使用 MediaStore
- 普通文件保存到 Downloads 集合
- 用户选择目录时使用 SAF
- 默认目录为 `Download/FastDrop`

---

## 12. 传输状态机

```text
CREATED
   │
   ▼
WAITING_ACCEPT
   │
   ├── REJECTED
   │
   ▼
PREPARING
   │
   ▼
TRANSFERRING
   │
   ├── PAUSED
   │      └── TRANSFERRING
   │
   ├── CANCELLED
   │
   ├── FAILED
   │      └── RETRYING
   │              └── TRANSFERRING
   │
   ▼
VERIFYING
   │
   ├── FAILED
   │
   ▼
COMPLETED
```

状态枚举：

```text
created
waiting_accept
preparing
transferring
paused
retrying
verifying
completed
failed
cancelled
rejected
```

---

## 13. 进度与速度计算

文件进度：

```text
progress = transferredBytes / totalBytes
```

批量任务进度：

```text
batchProgress =
所有文件已传输字节总和 / 所有文件总字节
```

建议使用 3 秒滑动窗口计算速度：

```text
speed = 最近 3 秒新增字节数 / 3 秒
```

预计剩余时间：

```text
remainingTime = remainingBytes / smoothedSpeed
```

更新频率：

- WebSocket 进度推送：200～500 ms 最多一次
- 数据库落盘：1～2 秒一次
- UI 刷新：约 200 ms 一次

---

## 14. 并发策略

第一阶段默认：

```text
同一文件并发分块：3
同时处理文件数：2
全局最大 HTTP 请求数：6
```

不要设置几十个并发，避免：

- 手机发热
- 路由器压力过大
- 磁盘随机写压力
- 超时增多
- 实际速度下降

---

## 15. 重试机制

建议指数退避：

```text
第 1 次：500 ms
第 2 次：1 s
第 3 次：2 s
第 4 次：4 s
第 5 次：8 s
```

单分块最多重试：

```text
5 次
```

可以自动重试：

- 网络中断
- 连接重置
- 请求超时
- 服务端临时繁忙
- 分块校验失败

不自动重试：

- 用户取消
- 用户拒绝
- Session 失效
- 磁盘空间不足
- 文件权限不足
- 文件已被删除

---

## 16. 完整性校验

文件级校验使用：

```text
SHA-256
```

接收完成后：

1. 确认分块完整
2. 校验文件总大小
3. 计算接收文件 SHA-256
4. 与发送方哈希比较
5. 校验成功后移动到正式目录

错误码：

```text
FILE_HASH_MISMATCH
```

---

## 17. 文件名与路径安全

必须防止：

```text
../
..\
C:\Windows\
/etc/passwd
```

处理方式：

- 仅保留基础文件名
- 过滤非法字符
- 禁止目录穿越
- 过滤 NUL 字符
- 检查 Windows 保留名称

Windows 非法字符：

```text
/
\
:
*
?
"
<
>
|
```

Windows 保留名称：

```text
CON
PRN
AUX
NUL
COM1～COM9
LPT1～LPT9
```

重名默认策略：

```text
photo.jpg
photo (1).jpg
photo (2).jpg
```

临时文件：

```text
video.mp4.fastdrop.part
```

校验成功后原子重命名为正式文件。

---

## 18. 磁盘空间检查

创建任务前检查：

```text
可用空间 >= 文件总大小 + 安全余量
```

安全余量：

```text
max(100 MB, 文件总大小 × 5%)
```

错误响应：

```json
{
  "code": "INSUFFICIENT_STORAGE",
  "message": "接收设备存储空间不足",
  "details": {
    "requiredBytes": 10737418240,
    "availableBytes": 5368709120
  }
}
```

---

## 19. 心跳与断线恢复

建议：

```text
每 15 秒发送一次 ping
连续 3 次没有 pong，判定断线
```

断线后：

1. 暂停创建新任务
2. 当前 HTTP 分块可短暂继续
3. 尝试恢复 WebSocket
4. 恢复后同步活动任务
5. 超过 60 秒失败则进入等待重连或失败状态

同步接口：

```http
GET /api/v1/transfers/active
```

---

## 20. REST API 汇总

### 系统接口

```http
GET /api/v1/health
GET /api/v1/server/info
GET /api/v1/capabilities
```

### 配对接口

```http
POST /api/v1/pair/request
GET  /api/v1/pair/requests/{requestId}
POST /api/v1/pair/requests/{requestId}/accept
POST /api/v1/pair/requests/{requestId}/reject
POST /api/v1/pair/token/refresh
```

### Session 接口

```http
GET    /api/v1/session
DELETE /api/v1/session
```

### 传输接口

```http
POST   /api/v1/transfers
GET    /api/v1/transfers
GET    /api/v1/transfers/{transferId}
POST   /api/v1/transfers/{transferId}/cancel
POST   /api/v1/transfers/{transferId}/retry
DELETE /api/v1/transfers/{transferId}
```

### 文件接口

```http
GET  /api/v1/transfers/{transferId}/files/{fileId}

PUT  /api/v1/transfers/{transferId}/files/{fileId}/chunks/{chunkIndex}
GET  /api/v1/transfers/{transferId}/files/{fileId}/chunks
POST /api/v1/transfers/{transferId}/files/{fileId}/complete

GET  /api/v1/transfers/{transferId}/files/{fileId}/content
HEAD /api/v1/transfers/{transferId}/files/{fileId}/content
```

---

## 21. 统一错误结构

```json
{
  "error": {
    "code": "TOKEN_EXPIRED",
    "message": "配对二维码已过期",
    "requestId": "request-uuid",
    "details": {}
  }
}
```

建议错误码：

```text
INVALID_REQUEST
UNSUPPORTED_PROTOCOL_VERSION

PAIR_TOKEN_INVALID
PAIR_TOKEN_EXPIRED
PAIR_TOKEN_ALREADY_USED
PAIR_REQUEST_REJECTED
PAIR_REQUEST_EXPIRED

SESSION_INVALID
SESSION_EXPIRED
SESSION_REVOKED

FILE_NOT_FOUND
FILE_NAME_INVALID
FILE_SIZE_MISMATCH
FILE_HASH_MISMATCH
CHUNK_INDEX_INVALID
CHUNK_HASH_MISMATCH

TRANSFER_NOT_FOUND
TRANSFER_CANCELLED
TRANSFER_ALREADY_COMPLETED

INSUFFICIENT_STORAGE
PERMISSION_DENIED
TOO_MANY_REQUESTS
INTERNAL_ERROR
```

---

## 22. 数据库设计

### 22.1 devices

```sql
CREATE TABLE devices (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    platform TEXT NOT NULL,
    app_version TEXT,
    last_ip TEXT,
    first_seen_at INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL
);
```

### 22.2 sessions

```sql
CREATE TABLE sessions (
    id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL,
    token_hash TEXT NOT NULL,
    source_ip TEXT,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    revoked_at INTEGER,
    FOREIGN KEY(device_id) REFERENCES devices(id)
);
```

Session Token 不明文保存，只存哈希。

### 22.3 transfers

```sql
CREATE TABLE transfers (
    id TEXT PRIMARY KEY,
    session_id TEXT,
    peer_device_id TEXT NOT NULL,
    direction TEXT NOT NULL,
    status TEXT NOT NULL,
    total_files INTEGER NOT NULL,
    total_bytes INTEGER NOT NULL,
    transferred_bytes INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    started_at INTEGER,
    completed_at INTEGER,
    error_code TEXT,
    error_message TEXT
);
```

### 22.4 transfer_files

```sql
CREATE TABLE transfer_files (
    id TEXT PRIMARY KEY,
    transfer_id TEXT NOT NULL,
    original_name TEXT NOT NULL,
    saved_name TEXT,
    source_path TEXT,
    target_path TEXT,
    mime_type TEXT,
    total_bytes INTEGER NOT NULL,
    transferred_bytes INTEGER NOT NULL DEFAULT 0,
    chunk_size INTEGER NOT NULL,
    total_chunks INTEGER NOT NULL,
    completed_chunks INTEGER NOT NULL DEFAULT 0,
    sha256_expected TEXT,
    sha256_actual TEXT,
    status TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    completed_at INTEGER,
    error_code TEXT,
    FOREIGN KEY(transfer_id) REFERENCES transfers(id)
);
```

### 22.5 分块状态

```sql
CREATE TABLE file_chunk_states (
    file_id TEXT PRIMARY KEY,
    completed_bitmap BLOB NOT NULL,
    updated_at INTEGER NOT NULL
);
```

---

## 23. Windows 服务端设计

第一阶段使用单进程：

```text
fastdrop.exe
├── HTTP Server
├── WebSocket Hub
├── Pairing Manager
├── Session Manager
├── Transfer Manager
├── Storage Manager
├── Database
├── QR Generator
└── Web UI Static Files
```

Vue 构建产物可嵌入 Go：

```go
//go:embed web/dist/*
var webAssets embed.FS
```

### 23.1 模块职责

#### Pairing Manager

- 创建一次性 Token
- 管理 Token 过期
- 防止重复使用
- 管理待确认请求
- 处理接受或拒绝

#### Session Manager

- 创建 Session
- 校验 Session
- 撤销 Session
- 处理过期
- 绑定设备和来源地址

#### Transfer Manager

- 创建任务
- 管理状态机
- 分块调度
- 进度统计
- 重试和取消

#### Storage Manager

- 创建临时文件
- 分块写入
- 检查空间
- 文件名净化
- 哈希计算
- 原子移动
- 重名处理

#### WebSocket Hub

- 长连接管理
- 心跳检测
- 消息推送
- 请求响应关联
- 状态同步

---

## 24. Go 项目目录

```text
fastdrop-desktop/
├── cmd/
│   └── fastdrop/
│       └── main.go
├── internal/
│   ├── api/
│   ├── websocket/
│   ├── pairing/
│   ├── session/
│   ├── transfer/
│   ├── storage/
│   ├── discovery/
│   ├── database/
│   ├── config/
│   └── security/
├── web/
│   ├── src/
│   ├── package.json
│   └── vite.config.ts
├── migrations/
├── tests/
├── go.mod
└── README.md
```

第一阶段即保留：

```text
internal/discovery/
```

为第二阶段 mDNS 做准备。

---

## 25. Flutter 手机端目录

```text
lib/
├── app/
│   ├── app.dart
│   ├── routes.dart
│   └── theme.dart
├── core/
│   ├── network/
│   ├── storage/
│   ├── security/
│   ├── errors/
│   └── utils/
├── features/
│   ├── pairing/
│   ├── devices/
│   ├── file_picker/
│   ├── transfer/
│   ├── history/
│   └── settings/
└── shared/
    ├── widgets/
    └── models/
```

状态管理推荐：

```text
Riverpod
```

或：

```text
Bloc
```

不建议仅使用 `setState` 管理全部传输状态。

---

## 26. 页面设计

### 26.1 手机首页

```text
┌──────────────────────────┐
│ FastDrop                 │
│                          │
│ 当前未连接               │
│                          │
│     [ 扫描电脑二维码 ]   │
│                          │
│ 最近连接                 │
│ Fang-PC                  │
│ 最后连接：昨天           │
│                          │
│ 传输记录        设置     │
└──────────────────────────┘
```

### 26.2 已连接页面

```text
已连接：Fang-PC
局域网直连
192.168.1.10

[发送图片]
[发送视频]
[发送文件]

正在传输
video.mp4        68%
42.3 MB/s        剩余 8 秒
```

### 26.3 Windows 首页

```text
┌────────────────────────────────────┐
│ FastDrop                           │
│                                    │
│ 手机扫码连接                       │
│                                    │
│          [二维码]                  │
│                                    │
│ 二维码将在 42 秒后刷新             │
│ 本机地址：192.168.1.10:9527        │
│                                    │
│ 已连接设备：Fang 的手机            │
│                                    │
│ 将文件拖到这里发送到手机           │
└────────────────────────────────────┘
```

---

## 27. Windows 网络和防火墙

首次运行提示：

```text
请允许 FastDrop 在“专用网络”中通信。
不建议开放“公用网络”。
```

网络接口处理：

1. 枚举活动网卡
2. 排除回环网卡
3. 排除 WSL、Docker、VPN 等虚拟网卡
4. 获取私有 IPv4
5. 允许用户选择服务网卡
6. 二维码使用手机可访问的真实局域网地址

需要处理：

- Wi-Fi 和网线同时连接
- VPN 网卡
- WSL 虚拟网卡
- Docker 网卡
- 手机热点
- 多个局域网地址

---

## 28. HTTP 服务安全

### 28.1 请求大小限制

```text
配对请求：最大 64 KB
普通 JSON：最大 1 MB
分块请求：chunkSize + 少量协议开销
```

### 28.2 速率限制

未认证接口：

```text
单 IP 每分钟最多 20 次配对请求
连续失败后临时封禁
```

### 28.3 超时设置

```text
ReadHeaderTimeout：5 秒
普通请求：15 秒
分块上传：60 秒
IdleTimeout：60 秒
WebSocket 心跳：15 秒
```

### 28.4 CORS

Web UI 和 API 尽量同源。

禁止：

```http
Access-Control-Allow-Origin: *
```

认证接口必须限制来源。

---

## 29. HTTPS 规划

第一阶段可先使用 HTTP，但安全边界是：

- 仅用于可信局域网
- 一次性 Token 防止随意配对
- Session Token 防止未授权调用
- HTTP 无法防止同网段监听

后续可以加入：

```text
临时自签证书
+
二维码携带证书指纹
+
App 证书固定
```

这部分建议作为第一阶段后的安全增强版本。

---

## 30. 第二阶段 mDNS 设计

### 30.1 服务类型

```text
_fastdrop._tcp.local.
```

实例名称：

```text
Fang-PC._fastdrop._tcp.local.
```

### 30.2 TXT 记录

```text
id=windows-device-uuid
name=Fang-PC
version=0.2.0
protocol=1
platform=windows
pairing=required
tls=0
```

TXT 中禁止包含：

- 一次性 Token
- Session Token
- 永久密码
- 文件路径
- 用户敏感数据

### 30.3 自动发现流程

```text
手机搜索 _fastdrop._tcp.local
        │
        ▼
解析服务地址、端口和 TXT
        │
        ▼
调用 GET /api/v1/server/info
        │
        ▼
验证协议版本
        │
        ▼
显示附近设备
        │
        ▼
用户点击连接
        │
        ▼
电脑端弹出配对确认
```

mDNS 只负责发现，不负责认证。

### 30.4 设备去重

同一电脑可能通过多个地址被发现。

使用：

```text
TXT 记录中的 deviceId
```

作为唯一设备标识。

地址选择优先级：

1. 与手机处于同网段
2. 私有 IPv4
3. `/health` 可访问
4. 网络延迟最低

---

## 31. Discovery 抽象

Go：

```go
type ServiceInfo struct {
    DeviceID        string
    DeviceName      string
    Host            string
    Port            int
    ProtocolVersion int
    Platform        string
}

type DiscoveryPublisher interface {
    Start(ctx context.Context, info ServiceInfo) error
    Stop() error
}
```

Flutter：

```dart
abstract interface class DeviceDiscovery {
  Stream<List<DiscoveredDevice>> discover();
  Future<void> stop();
}
```

实现：

```text
QrDiscovery
MdnsDiscovery
ManualDiscovery
```

---

## 32. 配置设计

配置文件位置：

```text
%APPDATA%/FastDrop/config.json
```

示例：

```json
{
  "server": {
    "port": 9527,
    "bindAddress": "auto"
  },
  "storage": {
    "downloadDirectory": "C:\\Users\\fang\\Downloads\\FastDrop",
    "conflictPolicy": "rename"
  },
  "transfer": {
    "chunkSize": 4194304,
    "maxConcurrentFiles": 2,
    "maxConcurrentChunks": 3
  },
  "security": {
    "pairTokenTtlSeconds": 60,
    "sessionTtlSeconds": 43200,
    "requireReceiveConfirmation": true
  },
  "discovery": {
    "mdnsEnabled": false
  }
}
```

---

## 33. 日志设计

日志字段：

```text
时间
日志级别
模块
requestId
sessionId 掩码
transferId
fileId
错误码
耗时
```

禁止记录：

- 完整 Token
- 二维码原始内容
- 用户文件内容
- 完整敏感路径

日志级别：

```text
DEBUG
INFO
WARN
ERROR
```

正式版本默认：

```text
INFO
```

---

## 34. 测试方案

### 34.1 单元测试

- Token 生成
- Token 过期
- Token 一次性使用
- Session 验证
- 文件名净化
- Windows 保留名称
- 重名处理
- 分块偏移
- 分块位图
- 状态机迁移
- SHA-256 校验
- 磁盘空间判断
- 协议版本兼容

### 34.2 集成测试

- 正常扫码配对
- 二维码过期
- Token 错误
- Token 重复使用
- 用户拒绝
- Session 过期
- WebSocket 断开重连
- 分块重复上传
- 分块乱序上传
- 传输中取消
- 磁盘空间不足
- 哈希不一致
- 文件重名
- 目录穿越攻击

### 34.3 文件规模测试

建议至少覆盖：

| 文件类型 | 大小 |
|---|---:|
| 小文本 | 1 KB |
| 普通图片 | 5 MB |
| 压缩包 | 100 MB |
| 视频 | 1 GB |
| 大文件 | 10 GB |
| 超大文件 | 50 GB |

### 34.4 网络异常测试

- 手机切换 Wi-Fi
- 网络瞬断
- 路由器重启
- 电脑睡眠后恢复
- 手机 App 切后台
- 上传过程中关闭电脑服务
- 防火墙阻断
- 多网卡切换

---

## 35. 第一阶段开发任务拆解

### 里程碑 1：基础服务

- 创建 Go 项目
- 创建 HTTP Server
- 创建 `/health`
- 获取局域网 IP
- 创建 Vue 页面
- 嵌入 Web 静态资源
- Windows 本地运行

### 里程碑 2：二维码配对

- 生成 pairId
- 生成一次性 Token
- Token 过期管理
- 生成二维码
- Flutter 扫码页面
- 配对请求接口
- Windows 接受/拒绝 UI
- 创建 Session

### 里程碑 3：控制通道

- WebSocket Server
- Flutter WebSocket Client
- Session 认证
- 心跳
- 断线重连
- 通用消息结构
- 统一错误结构

### 里程碑 4：手机上传电脑

- 文件选择
- 创建传输任务
- 4 MB 分块
- HTTP 分块上传
- 临时文件写入
- 进度显示
- 取消和重试
- SHA-256
- 原子移动

### 里程碑 5：电脑发送手机

- Windows 拖拽文件
- `file.offer`
- 手机确认
- HTTP Range 下载
- Android 文件保存
- 下载进度
- 完整性校验

### 里程碑 6：工程完善

- SQLite
- 历史记录
- 文件重名
- 磁盘空间检查
- 安全限制
- 日志
- 单元测试
- 安装包
- Windows 防火墙引导

---

## 36. 第二阶段开发任务拆解

- Go mDNS 服务发布
- Flutter mDNS 搜索
- `_fastdrop._tcp.local`
- TXT 元数据
- 自动设备列表
- deviceId 去重
- 多网卡地址选择
- `/health` 可达性检查
- 协议版本兼容提示
- 二维码兜底
- 手动 IP 连接

---

## 37. 第一阶段验收标准

第一阶段成功标准：

1. Android 与 Windows 位于同一 Wi-Fi。
2. Windows 显示二维码。
3. Android 扫码后发起连接。
4. Windows 用户确认后建立 Session。
5. Android 可以发送多个文件到 Windows。
6. Windows 可以拖拽文件发送到 Android。
7. 支持至少 10 GB 单文件。
8. 传输过程内存占用稳定。
9. 网络短暂中断后可以重试。
10. 文件完成后 SHA-256 一致。
11. 目录穿越和非法文件名无法生效。
12. 传输过程中可以取消任务。
13. 文件重名不会默认覆盖原文件。
14. 错误信息清晰可定位。
15. 电脑和手机界面都能显示速度和进度。

---

## 38. 最终推荐方案

```text
手机端：Flutter Android
电脑端：Go + Vue 3
数据库：SQLite
配对：二维码 + 一次性 Token
认证：短期 Session Token
控制：WebSocket
传输：HTTP 分块上传 + HTTP Range 下载
完整性：SHA-256
默认分块：4 MB
第一阶段：二维码
第二阶段：mDNS
兜底：二维码 + 手动 IP
```

该方案的核心优势：

- 实现难度可控
- 安全边界清晰
- 支持大文件
- 支持断点续传扩展
- 兼容多平台扩展
- 不依赖云端服务器
- 第一阶段可以快速形成可用产品
- 第二阶段可以平滑增加自动发现能力
