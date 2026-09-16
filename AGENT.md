# ZLinks Maintenance Notes

## Project Role

ZLinks is a SwiftUI iOS app for connecting to Nikon cameras over Wi-Fi and reading camera metadata and storage status. The camera transport currently uses PTP/IP over TCP port `15740`.

Verified against Nikon Z5 (`FriendlyName=Z5_2_8064268`, firmware string `V1.20`) over STA/LAN and camera AP paths.

## Connection Flow

1. `CameraConnectionSheet` presents three modes:
   - AP mode: the camera creates the Wi-Fi network. `CameraWiFiService` uses `NEHotspotConfiguration` to ask iOS to join a user-provided SSID. The system owns the confirmation UI and routing decision.
   - STA mode: the camera joins an existing LAN or phone hotspot.
   - USB mode: the camera is wired to the device. `USBCameraLink` drives ImageCaptureCore; every read (metadata, gallery, downloads, live view) goes over the cable. See “USB 有线连接” below.
2. `CameraDiscoveryService` finds hosts on the active IPv4 Wi-Fi subnet by probing TCP port `15740`. This is a best-effort discovery mechanism, not an SSID scanner.
3. `CameraConnectionService` opens two TCP connections to the camera:
   - command connection: PTP/IP Init Command, then PTP operations;
   - event connection: PTP/IP Init Event, kept separate from command traffic.
4. The command connection opens PTP session `1`, requests `GetDeviceInfo`, then performs optional status reads for battery, storage, object count, and lens properties.
5. Connection debug logs are not shown inside the connection sheet. Open them from the “我的相机” toolbar `info.circle` button, which presents a dedicated full-screen log drawer.

## USB 有线连接（USB Link）

主页面连接方式除 AP / STA 外新增 `USB 有线`，由 `USBCameraLink`（ImageCaptureCore）实现。一次连接同时提供两条通道：

1. **PTP 直通**：`ICCameraDevice.requestSendPTPCommand` 承载 PTP 命令容器。`USBPTPChannel` 把上层现有的 PTP/IP 报文翻译成 PTP 容器，再把响应还原成 PTP/IP 报文，因此 `CameraConnectionService.operation`、事务号、超时、数据分片逻辑在 Wi-Fi 与 USB 上完全一致。
   - 相机会话由 `ICDeviceBrowser` 建立（`requestOpenSession`）。App 自己的 `OpenSession` 返回 `0x201E` 时按“会话已存在”处理，不视为失败。
   - 命令容器的 4 字节长度前缀在不同系统版本上要求不一致：连接时会用 `OpenSession` + `GetDeviceInfo` 依次尝试 `standard` 与 `lengthLess` 两种拼装方式，并缓存可用的那一种。
   - 系统回调返回的两个 `Data` 可能是（响应容器, 数据容器），也可能是相反顺序，因此按容器类型（1=命令 / 2=数据 / 3=响应）判定，不依赖参数位置。
   - 相机返回的事务号可能与请求不同，`USBPTPChannel` 统一回填调用方的事务号。
2. **内容目录**：`ICCameraDevice.contents` 提供目录与对象列表，`requestThumbnailData` 取缩略图，`requestReadData(atOffset:length:)` 以 8 MB 分块读取原图。图库列表 / 缩略图 / 原图下载不再逐条走 PTP 轮询。

链路选择与降级：

- `CameraConnectionService.linkKind` 记录当前链路，`isUSBPTPReady` 表示 USB 上的 PTP 直通是否可用。
- 相机不提供 PTP 直通时仍可用 USB 目录模式浏览与下载照片：相机信息来自 `ICDevice`（名称 / 序列号），电量来自 `ICCameraDevice.batteryLevel`，实时图传与参数控制不可用。
- USB 断线由 ImageCaptureCore 回调通知（`didCloseSessionWithError` / `didRemove`），不参与 PTP/IP 自动重连；`beginAutomaticReconnect` 只处理 Wi-Fi。
- USB 快速连接默认开启并通过 `camera.usbFastConnect` 持久化。关闭时沿用系统内容目录优先；开启时连接不等待内容目录，图库优先走 PTP，只有 PTP 刷新失败才等待并读取系统内容目录兜底。
- 每次手动刷新都会重建目录快照，因此刚拍下的照片会出现在图库里。

## 性能要点（实时图传 / 图库）

- 实时画面放在 `LiveViewStream` 中单独发布。若挂在 `CameraConnectionService` 的 `@Published` 属性上，每一帧都会重建整个 Tab 层级。
- 实时 JPEG 在后台线程解码（`decodeLiveViewJPEG` + `CGImageSource`）并立即展开位图，避免主线程每帧解码。
- 拉帧操作使用 `.background` 优先级，图库缩略图与状态刷新可随时插队；循环中不再固定 `sleep(33ms)`，仅让出一次执行权。
- USB 原图下载改用系统读取通道，分块 8 MB；Wi-Fi 仍使用 `GetPartialObject` 的 4 MB 分块。

## Successful Connection Checklist

A healthy session should reach these stages in order:

1. Command TCP ready on port `15740`.
2. `InitCommandRequest` accepted and `InitCommandAck` returned.
3. Event TCP ready.
4. `InitEventRequest` accepted and `InitEventAck` returned.
5. `OpenSession` response code `0x2001`.
6. `GetDeviceInfo` returns `StartData`/`EndData` plus response code `0x2001`.
7. `DeviceInfo` parses manufacturer/model/version/serial without bounds errors.
8. Optional status probes for battery (`0x5001`), storage IDs/info, and object count.
9. Optional lens probes via `GetDevicePropValue`:
   - Nikon `LensID` `0xD0E0`
   - Nikon `FocalLengthMin/Max` `0xD0E3` / `0xD0E4` (value / 100 = mm)
   - Nikon `MaxApAtMin/MaxFocal` `0xD0E5` / `0xD0E6` (value / 100 = f-number)
   - Standard current `FocalLength` `0x5008` and `FNumber` `0x5007` (value / 100)
   Lens reads are best-effort and must not tear down a successful camera session.

If step 2 or 4 fails, the failure is still in PTP/IP session setup. If steps 2-6 succeed and the UI still reports "相机返回了无法识别的数据。", the bug is almost always local dataset parsing, not network discovery.

## Lessons From The First Successful Connect

These mistakes blocked connection even after the camera was already talking correctly. Do not reintroduce them.

### 1. `InitCommandAck` friendly name is not a PTP counted string

Wrong assumption:

- Treat offset 20 as a PTP string whose first byte is a character count.

Actual Nikon layout after the 8-byte packet header is removed:

```text
u32 connectionNumber
u8[16] cameraGUID
UTF-16LE friendlyName + 0x0000 terminator
u32 protocolVersion   // observed 0x00010000
```

Observed failure:

```text
payload starts name bytes with 5A 00 ...
parser treated 0x5A ('Z') as characterCount=90
end offset became 201 while payload was only 50 bytes
error: PTP 字符串长度越界 / 相机返回了无法识别的数据。
```

Correct behavior:

- Scan from offset 20 for a UTF-16 little-endian null terminator.
- Decode the name with `.utf16LittleEndian`.
- Read the trailing 4-byte protocol version after the terminator.
- Send the initiator name the same way in `InitCommandRequest` via `utf16NullTerminatedString`, not `ptpString`.

### 2. `DeviceInfo` field order must keep `FunctionalMode` after the vendor extension string

Correct order for the Nikon Z5 payload:

```text
u16 StandardVersion
u32 VendorExtensionID
u16 VendorExtensionVersion
PTPString VendorExtensionDesc
u16 FunctionalMode
u32 + u16[] OperationsSupported
u32 + u16[] EventsSupported
u32 + u16[] DevicePropertiesSupported
u32 + u16[] CaptureFormats
u32 + u16[] ImageFormats
PTPString Manufacturer
PTPString Model
PTPString DeviceVersion
PTPString SerialNumber
```

Observed successful offsets from the Z5 dump:

```text
offset 0: StandardVersion / VendorExtensionID / VendorExtensionVersion
offset 8: VendorExtensionDesc = "Microsoft.com/DeviceServices: 1.0"
offset 77: FunctionalMode = 0x0000
offset 79: OperationsSupported count begins
later: Manufacturer = "Nikon Corporation"
model = "Z5_2"
version = "V1.20"
serial ends with "8064268"
```

Wrong assumptions that failed:

- Skip 2 bytes for `FunctionalMode` immediately after offset 8, before the vendor extension string.
- Start operation arrays immediately after the vendor extension string and ignore `FunctionalMode`.

Both produce a bogus 32-bit array count and then fail bounds checks, even though `GetDeviceInfo` itself returned `0x2001` with a full payload.

### 3. Keep two different string encodings separate

There are two string formats in this transport:

- PTP dataset strings: 1-byte UTF-16 code-unit count, including the terminating null code unit. Used inside `DeviceInfo`, storage info, and similar datasets.
- PTP/IP init friendly names: raw UTF-16LE bytes terminated by `0x0000`. Used by `InitCommandRequest` / `InitCommandAck`.

Never parse one with the helper written for the other.

### 4. Session setup details that worked

- Initiator GUID: stable 16-byte value, currently `00 11 22 33 44 55 66 77 88 99 AA BB CC DD EE FF`.
- Initiator name: `ZLinks iOS` as UTF-16LE null-terminated.
- Protocol version: `0x00010000`.
- Separate command and event TCP sockets to the same host/port.
- `InitEventRequest` carries only the connection number from `InitCommandAck`.
- `OpenSession` parameter session ID `1`.
- `OperationRequest` payload layout:

```text
u32 DataPhaseInfo
u16 operationCode
u32 transactionID
u32[] parameters
```

- `DataPhaseInfo`:
  - `1` for no-data and data-in operations used by the current client
  - `2` reserved for data-out if needed later
- Transaction IDs start at `1` and increment for each operation.
- Status probes after connect must be best-effort. A missing battery or storage property must not tear down an otherwise successful session.

### 5. Debug log is the source of truth during protocol work

All connection logs live in the full-screen “连接日志” drawer opened from the “我的相机” toolbar `info.circle` button. Do not put the packet dump back into the connection sheet. When a connect fails:

1. Confirm whether `InitCommandAck` / `InitEventAck` / `OpenSession` / `GetDeviceInfo` response codes arrived.
2. If those succeeded, inspect the parser offsets rather than Wi-Fi discovery.
3. Copy the hex dumps for the failing packet and check string encoding and field order before changing transport code.

Useful log markers:

```text
InitCommandAck FriendlyName=...
InitEventAck
OpenSession code=0x2001
GetDeviceInfo code=0x2001 dataBytes=...
DeviceInfo VendorExtension offset=...
DeviceInfo FunctionalMode=...
DeviceInfo 解析成功 manufacturer=... model=...
```

## PTP/IP Parsing Rules

- PTP/IP packet headers are little-endian: 4-byte total length followed by 4-byte packet type.
- Packet types used by the current client:
  - `1` InitCommandRequest
  - `2` InitCommandAck
  - `3` InitEventRequest
  - `4` InitEventAck
  - `5` InitFail
  - `6` OperationRequest
  - `7` OperationResponse
  - `9` StartData
  - `10` Data
  - `12` EndData
- `InitCommandRequest` uses protocol version `0x00010000` and a stable 16-byte initiator GUID.
- `InitCommandAck` friendly name is UTF-16LE null-terminated, not a PTP counted string.
- `DeviceInfo` keeps `FunctionalMode` after the vendor extension PTP string.
- PTP dataset strings use a one-byte UTF-16 code-unit count and include a terminating null code unit.
- Array counts in PTP datasets are 32-bit little-endian values followed by `count * 2` bytes of `u16` entries.
- Do not turn a malformed packet into a generic success. Keep bounds checks at every variable-length field and preserve the specific protocol error where possible.
- Prefer logging the actual packet type, hex dump, and parser offset when throwing `malformedPacket`.

## Wi-Fi Platform Constraints

iOS public APIs do not allow a normal App Store app to scan and enumerate nearby Wi-Fi SSIDs. Do not implement a fake `NIKON_` scan based on unavailable APIs. The supported flow is to accept a known SSID and optional password, call `NEHotspotConfigurationManager`, wait for the system operation to complete, then scan for PTP/IP hosts after the interface has settled.

Joining a camera AP does not guarantee simultaneous cellular routing. `joinOnce` and cellular fallback are controlled by iOS and device settings; the app must not promise or force this behavior.

## Files and Responsibilities

- `ZLinks/Service/CameraConnectionService.swift`: PTP/IP transport, packet framing, PTP operations, dataset parsing, camera status, lens info, and connection debug log.
- `ZLinks/Service/CameraDiscoveryService.swift`: active-subnet discovery by TCP port probe.
- `ZLinks/Service/CameraWiFiService.swift`: iOS-managed AP network join request.
- `ZLinks/HomeView/MyCameraView.swift`: camera status UI, lens info card, connection sheet, and the full-screen connection log drawer opened from the toolbar info button.
- `ZLinks/HomeView/GalleryView.swift`: camera storage gallery grid. Loads object handles/info over PTP, shows a 4-column newest-first thumbnail list, and overlays video duration when available.
- `ZLinks/HomeView/CaptureView.swift`: capture tab. Owns a full-width 4:3 live-view preview and starts/stops remote live view while the tab is visible.
- `CameraConnectionService` is owned by `ZLinksApp` and shared across tabs through `environmentObject`.

## Gallery / Media Listing

Gallery browsing uses standard PTP operations after an existing session is open:

1. `GetObjectHandles` (`0x1007`) for all objects on storage
2. `GetObjectInfo` (`0x1008`) to filter media and sort by capture/modification date (newest first)
3. `GetThumb` (`0x100A`) for JPEG thumbnails
4. Optional MTP `GetObjectPropValue` (`0x9803`) with Duration `0xDC89` for video length

Folders/associations are skipped. Image/video detection uses ObjectFormat plus filename extension (JPG/NEF/MOV/MP4, etc.). Thumbnail and duration requests share the command connection through a serial operation gate so concurrent cell loads cannot interleave PTP/IP transactions.

## Lens Info

Lens data is shown in a separate rounded card on “我的相机”, independent from the camera status card.

Card layout:

- top-left title: `镜头信息`
- top-right connection state capsule: `未连接` / `已连接` / `未知` / `未安装` / transient camera states
- primary line: numeric lens ID only (`镜头 ID n`); no friendly lens model name is available from these properties
- 2x2 metric modules: `焦距范围`, `光圈范围`, `当前焦距`, `当前光圈`

Property scale:

- focal length properties use millimetres * 100
- aperture properties use f-number * 100

Missing properties must leave the corresponding module as `--` and keep the camera session alive. Toolbar refresh reloads both camera status and lens info.



## Capture / Live View

Entering the Capture tab starts Nikon live view over the existing PTP/IP command session. Leaving the tab stops the stream so gallery and status traffic can use the command channel.

Pipeline:

1. Prefer `StartLiveView` (`0x9201`) without forcing PC mode first, so the camera body monitor can keep working.
2. If start fails and the camera advertises it, optionally send `ChangeApplicationMode` (`0x9435`, param `1`) and retry start.
3. Poll `DeviceReady` (`0x90C8`) until OK or short timeout. `DeviceBusy` (`0x2019`) means keep waiting.
4. Loop `GetLiveViewImage` (`0x9203`); fall back to `GetLiveViewImageEx` (`0x9428`) when needed.
5. Live-view object payload is a metadata header plus JPEG. Decode by scanning for `FF D8` … `FF D9`.
6. On stop: cancel the pull loop and send `EndLiveView` (`0x9202`).

All live-view transactions share the same serial operation gate as gallery thumbnails.
## Capture Physical Keys

The Capture tab renders a landscape-oriented live-view monitor with liquid-glass key rails on both sides in landscape, and a glass key grid in portrait. A full-screen button on the monitor opens a tab-bar-free monitoring surface with the same camera controls distributed across the left and right glass rails. Tapping a camera key opens a slider editor instead of cycling immediately. Dragging the slider sends the latest value through a coalescing write queue, writes via `SetDevicePropValue` (`0x1016`), and reads the value back so clamped values are reflected in the UI.

PTP/IP data-out transactions use `DataPhaseInfo=2`: send `StartData` with transaction ID, total byte count and a zero reserved field, then one `Data`/`EndData` packet with transaction ID plus payload, then receive `OperationResponse`.

Mapped camera properties:

| Code | Value | Encoding / important values |
|---|---|---|
| `0x5007` | FNumber | UInt16, value / 100 |
| `0x5005` | WhiteBalance | UInt16; Nikon: Auto `0x0002`, Daylight `0x0004`, Fluorescent `0x0005`, Tungsten `0x0006`, Flash `0x0007`, Cloudy `0x8010`, Shade `0x8011` |
| `0xD061` | LiveViewAFFocus / StillFocusMode | UInt8; Nikon Z5 real-time view: AF-S `0`, AF-C `1`, MF `4`. Standard `0x500A` is read-only on Z5 and is used only as a fallback for older bodies. |
| `0x500B` | ExposureMeteringMode | UInt16: Average `0x0001`, CenterWeighted `0x0002`, MultiSpot/Matrix `0x0003`, CenterSpot `0x0004` |
| `0x500D` | ExposureTime | UInt32; standard Nikon scalar value / 10000 = seconds. Nikon `0xD100` fallback uses packed `(numerator << 16) | denominator` |
| `0x500E` | ExposureProgramMode | UInt16: M `0x0001`, P `0x0002`, A `0x0003`, S `0x0004`, Nikon Auto `0x8010` |
| `0x500F` | ExposureIndex / ISO | UInt16 integer |
| `0x5010` | ExposureBiasCompensation | Int16, value / 1000 EV |

If standard `0x500D` rejects a Nikon shutter write, retry via Nikon vendor `0xD100`. Grid and horizontal preview mirror are local real-time overlays and do not modify the camera.

Useful log markers:

```text
DeviceInfo ... liveView=[StartLiveView,EndLiveView,GetLiveViewImg,...]
[liveview] 开始启动实时图传
[liveview] DeviceReady OK
[liveview] 拉流循环开始
[liveview] EndLiveView
```

## Nikon Capture-Related Operations (reference)

These opcodes are commonly useful for later capture-tab features. Support still depends on each body's `DeviceInfo.OperationsSupported`.

| Opcode | Name | Notes |
|---|---|---|
| `0x100E` | `InitiateCapture` | Standard still capture trigger |
| `0x1014` | `GetDevicePropDesc` | Enumerate allowed property values |
| `0x1015` | `GetDevicePropValue` | Read current exposure/focus/etc. |
| `0x1016` | `SetDevicePropValue` | Write current exposure/focus/etc. |
| `0x90C7` | `GetEvent` | Nikon vendor event poll |
| `0x90C8` | `DeviceReady` | Wait out busy after start/capture |
| `0x9200` | `GetPreviewImg` | Gallery/full-image preview helper |
| `0x9201` | `StartLiveView` | Enable live view stream |
| `0x9202` | `EndLiveView` | Disable live view stream |
| `0x9203` | `GetLiveViewImg` | Pull one live-view JPEG object |
| `0x9204` | `MfDrive` | Manual focus drive |
| `0x9205` | `ChangeAfArea` | Move AF area (`X`, `Y`) |
| `0x9206` | `AfDriveCancel` | Cancel AF drive |
| `0x9207` | `InitiateCaptureRecInMedia` | Capture to card while remote-controlled. Requires operation parameters: send `[0xFFFFFFFF, 0]` (no AF, card target); retry with `[0xFFFFFFFF]` only when the body returns `0x2006` or `0x201D`. Wait for `DeviceReady` after success. |
| `0x920A` | `StartMovieRecInCard` | Start movie recording to card |
| `0x920B` | `EndMovieRec` | Stop movie recording |
| `0x9428` | `GetLiveViewImageEx` | Z-series extended live-view object |
| `0x9435` | `ChangeApplicationMode` | App/PC control mode gate on some Z bodies |

Common device properties for capture UI later:

| Code | Name | Decode |
|---|---|---|
| `0x5001` | BatteryLevel | percent |
| `0x5007` | FNumber | value / 100 |
| `0x5008` | FocalLength | value / 100 mm |
| `0x500A` | FocusMode | vendor-specific enums |
| `0x500D` | ExposureTime / Shutter | often hi/lo 16-bit fraction |
| `0x500E` | ExposureProgramMode | P/A/S/M style |
| `0x500F` | ExposureIndex (ISO) | integer ISO |
| `0x5010` | ExposureBiasCompensation | 1/1000 EV style on many bodies |

## Verification Notes

- Prefer building from the Xcode app / workspace tools when the project format is newer than the CLI `xcodebuild` installation.
- After protocol changes, reconnect to a real camera and confirm the checklist markers above in the in-app debug log.
- A green path ends with `DeviceInfo 解析成功` and UI state `.connected`. If only status metrics show "不可用", treat that as optional property support, not a connection failure.
