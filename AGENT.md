# ZLinks Maintenance Notes

## Project Role

ZLinks is a SwiftUI iOS app for connecting to Nikon cameras over Wi-Fi and reading camera metadata and storage status. The camera transport currently uses PTP/IP over TCP port `15740`.

Verified against Nikon Z5 (`FriendlyName=Z5_2_8064268`, firmware string `V1.20`) over STA/LAN and camera AP paths.

## Connection Flow

1. `CameraConnectionSheet` presents two modes:
   - AP mode: the camera creates the Wi-Fi network. `CameraWiFiService` uses `NEHotspotConfiguration` to ask iOS to join a user-provided SSID. The system owns the confirmation UI and routing decision.
   - STA mode: the camera joins an existing LAN or phone hotspot.
2. `CameraDiscoveryService` finds hosts on the active IPv4 Wi-Fi subnet by probing TCP port `15740`. This is a best-effort discovery mechanism, not an SSID scanner.
3. `CameraConnectionService` opens two TCP connections to the camera:
   - command connection: PTP/IP Init Command, then PTP operations;
   - event connection: PTP/IP Init Event, kept separate from command traffic.
4. The command connection opens PTP session `1`, requests `GetDeviceInfo`, then performs optional status reads for battery, storage, and object count.
5. Connection debug logs are not shown inside the connection sheet. Open them from the “我的相机” toolbar `info.circle` button, which presents a dedicated full-screen log drawer.

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

- `ZLinks/Service/CameraConnectionService.swift`: PTP/IP transport, packet framing, PTP operations, dataset parsing, camera status, and connection debug log.
- `ZLinks/Service/CameraDiscoveryService.swift`: active-subnet discovery by TCP port probe.
- `ZLinks/Service/CameraWiFiService.swift`: iOS-managed AP network join request.
- `ZLinks/HomeView/MyCameraView.swift`: camera status UI, connection sheet, and the full-screen connection log drawer opened from the toolbar info button.

## Verification Notes

- Prefer building from the Xcode app / workspace tools when the project format is newer than the CLI `xcodebuild` installation.
- After protocol changes, reconnect to a real camera and confirm the checklist markers above in the in-app debug log.
- A green path ends with `DeviceInfo 解析成功` and UI state `.connected`. If only status metrics show "不可用", treat that as optional property support, not a connection failure.
