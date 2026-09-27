# Terabyte Network Manager — Phase 1: Huawei ONT Session & API Discovery

A production-grade Android application and client engine designed to manage authorized Huawei ONT/ONU devices via their native web management interfaces.

---

## 1. Executive Summary & Design Principles

The primary priority of Phase 1 is **not the UI**, but establishing the **real authenticated session and API communication** used by target Huawei Optical Network Terminals (ONTs).

### Strict Behavioral Mandates:
1. **Never guess API endpoints or invent responses:** All endpoints, data structures, and parsers are based on verified Huawei ONT WebUI protocols.
2. **Unsupported Features return `NOT_SUPPORTED`:** If an ONT hardware model or firmware does not expose an endpoint, the system returns `OntResult.NotSupported`. It never fakes zero counters or placeholders.
3. **Absolute Credential & Token Protection:**
   - Passwords and session cookies/tokens are never logged, never printed to console, and never exposed to the UI layer.
   - Credentials saved locally are encrypted using AES-256 GCM backed by the **Android KeyStore**.
   - Outgoing and incoming traffic passes through `SafeLoggingInterceptor`, which redacts `PassWord`, `onttoken`, `x.X_HW_Token`, `sessionID`, `Cookie`, and `Authorization` headers.

---

## 2. Target Device Matrix

| Target Model | Class | PON Standard | Typical Firmware | WebUI Signature & Endpoints |
|---|---|---|---|---|
| **Huawei HG8145C** (Target 1) | Single-Band 2.4G | GPON Class B+ | `V300R015C10`<br>`V300R017C10` | Embedded ASP, JavaScript constructor arrays (`stDeviceInfo`, `stOpticInfo`, `WanInfo`, `UserDevInfo`, `EthStatus`), `onttoken` CSRF form authentication. |
| **Huawei HG8145V5** | Dual-Band AC1200 | GPON Class B+ | `V300R019C00`<br>`V500R019C00` | Hybrid ASP / modern UI, dual-band Wi-Fi management, challenge salt SHA-256. |
| **Huawei EG8145V5** | Dual-Band AC1200 | GPON Class B+ | `V500R019C20` | EchoLife enhanced WebUI, JSON/ASP mixed telemetry. |
| **Huawei EG8147X6** | Dual-Band Wi-Fi 6 AX3000 | GPON Class C+ | `V500R019C20`<br>`V500R020C10` | OptiXstar series, modern REST API endpoints (`/api/system/*`, `/api/lan/*`), dual-band 802.11ax. |
| **Huawei EG8147X6-10** | Dual-Band Wi-Fi 6 AX3000 | GPON Class C+ | `V500R021C00` | OptiXstar series with CATV / RF video port. |

---

## 3. Discovered Huawei ONT Protocol & Session Behavior

### A. Connection & Interface Discovery (`HuaweiOntDiscovery`)
Rather than assuming `/login` or `/api`, the discovery engine executes a systematic probe:
1. Validates host IP/FQDN format.
2. Probes base URL (`/`) on configured protocols (HTTP port 80 / HTTPS port 443).
3. Detects server banner (e.g. `micro_httpd`, `GoAhead-Webs`, `Huawei Web Server`).
4. Follows any HTTP 302 redirects, `<meta http-equiv="refresh">` tags, or JavaScript redirects (`window.top.location = ...`).
5. Locates login form inputs (`txt_Username`, `txt_Password`, `PassWord`, `UserName`) and extracts the form action URL (e.g. `/login.cgi` or `/index.asp`).
6. Identifies pre-authentication anti-CSRF tokens (`onttoken`, `x.X_HW_Token`) and random challenge salts (`randId`, `salt`).
7. Checks `asp/GetFeatureInfo.asp` for pre-auth model and firmware identifiers.

### B. Authentication Mechanisms (`HuaweiAuthEngine`)
Huawei ONTs employ one of several authentication techniques depending on model and firmware release:
- **Challenge SHA-256 (`AuthType.CHALLENGE_SHA256`):**
  - ONT provides a random salt string via pre-auth page or `/asp/ajaxGetChallenge.asp`.
  - Client computes `SHA256(password + salt)` or `SHA256(SHA256(password) + salt)` and submits `UserName` and hashed `PassWord`.
- **Form POST with Anti-CSRF Token (`AuthType.PLAIN_FORM_TOKEN`):**
  - Classic HG8145C models extract `onttoken` from hidden DOM elements and post directly to `/login.cgi`.
- **Concurrency & Lockout Handling:**
  - Huawei ONTs enforce a strict single-concurrent-session policy. If another administrator is logged into the web console, the ONT returns `ErrUserAlreadyLogin` or error code `1001`. The auth engine catches this and produces a safe error message without leaking sensitive data.

### C. Session Maintenance (`HuaweiSessionManager`)
- **State Storage:** In-memory `HuaweiSessionInfo` tracking `sessionId`, `csrfToken`, and timeout timestamp (typically 10 minutes on Huawei ONTs).
- **Keepalive & Expiration Detection:** Checks response codes (302/401/403) and body redirect scripts.
- **Transparent Re-authentication:** If a request expires during active administration, `HuaweiSessionManager` automatically re-authenticates with the cached Keystore credentials and retries the command once.
- **Secure Clearance:** `logout()` posts to `/logout.cgi` and immediately wipes session tokens, cookies, and keys from memory.

---

## 4. Response Parsing Architecture

Huawei ONTs do not typically expose standard JSON APIs on older firmware. Instead, data is embedded inside JavaScript scripts as constructor calls or variable declarations. The response parsers handle both legacy JavaScript and modern JSON:

### 1. Device Info (`HuaweiDeviceInfoParser`)
- **Legacy JS Array:**
  ```javascript
  function stDeviceInfo(domain, model, swVer, hwVer, sn, mac, desc) { ... }
  var DeviceInfo = new Array(new stDeviceInfo("InternetGatewayDevice.DeviceInfo", "HG8145C", "V3R015C10S106", "VER.A", "48575443F291A804", "00:E0:FC:88:99:AA", "EchoLife HG8145C GPON Terminal"));
  ```
- **Modern JSON:**
  ```json
  {"modelName": "EG8147X6", "softwareVersion": "V500R019C20SPC120", "hardwareVersion": "10AD.A", "sn": "48575443ABCDEF01"}
  ```

### 2. Optical Telemetry (`HuaweiOpticalInfoParser`)
- **Legacy JS Array (`opticinfo.asp`):**
  ```javascript
  function stOpticInfo(domain, rxPower, txPower, transVoltage, biasCurrent, optTemp) { ... }
  var OpticInfo = new Array(new stOpticInfo("InternetGatewayDevice.X_HW_DEBUG.SMP.OpticInfo", "-21.45", "2.35", "3280", "15", "45"));
  ```
  - `rxPower`: `-21.45 dBm` (Normal GPON range is -8.0 dBm to -27.0 dBm).
  - `txPower`: `+2.35 dBm` (Normal GPON range is +0.5 dBm to +5.0 dBm).
  - `transVoltage`: `3280 mV` normalized to `3.28 V`.
  - `biasCurrent`: `15 mA`.
  - `optTemp`: `45 °C`.
  - Fiber unplugged (`--` / `N/A`) automatically triggers `losState = "LOS"` and `ponState = "Down"`.

### 3. WAN Interfaces (`HuaweiWanParser`)
- Extracts interface name, connection status (`Connected`/`Disconnected`), IP address, subnet mask, gateway, DNS servers, VLAN ID, service type (`INTERNET`, `IPTV`, `VOIP`), and IPv6 addresses.

### 4. Connected Clients (`HuaweiClientParser`)
- Parses active LAN and WLAN clients from `userdevinfo.asp`, mapping interface names to `ConnectionType.ETHERNET`, `WIRELESS_2_4G`, or `WIRELESS_5G`.

### 5. Ethernet Ports (`HuaweiEthernetParser`)
- Parses LAN1 through LAN4 link states (`UP`/`DOWN`), duplex, and negotiated speeds (`1000M`, `100M`).

### 6. Traffic Stats (`HuaweiTrafficParser`)
- Extracts upload and download byte counters and packet statistics from `getwanflux.asp`.

---

## 5. Device Adapter Architecture & Factory Dispatch

The application abstracts hardware differences behind `HuaweiOntClient`:

```
                 HuaweiOntClient (Interface)
                             ▲
                             │
     ┌───────────────────────┴───────────────────────┐
     │                                               │
BaseHuaweiAdapter                           MockHuaweiOntClient
     ▲                                      (Development / Mock)
     ├─────────────────┬─────────────────┬─────────────────┐
     │                 │                 │                 │
HG8145CAdapter   EG8147X6Adapter   HG8145V5Adapter   GenericHuaweiAdapter
(EchoLife V300)  (Wi-Fi 6 AX3000)  (Dual-Band AC)    (Dynamic Probing)
```

### Dynamic Dispatch in `HuaweiOntClientFactory`:
The client adapter is chosen based on **Model + Firmware + Capabilities**, rather than just model name:
- If `config.isMock == true` -> `MockHuaweiOntClient`
- `HG8145C` or firmware containing `V300R015`/`V300R017` -> `HG8145CAdapter`
- `EG8147X6` or `EG8147X6-10` or (`V500R019` with Wi-Fi 6) -> `EG8147X6Adapter`
- `HG8145V5` -> `HG8145V5Adapter`
- `EG8145V5` -> `EG8145V5Adapter`
- Uncatalogued custom ONT models -> `GenericHuaweiAdapter`

---

## 6. Security Architecture

1. **Keystore-Backed AES-256 GCM:**
   - Passwords saved in the application are encrypted via `KeystoreManager` using an AES-256 GCM key generated inside the hardware-backed `AndroidKeyStore`.
2. **Safe Logging Interceptor (`SafeLoggingInterceptor`):**
   - Automatically sanitizes HTTP request URLs, query parameters, headers, and form/JSON bodies.
   - Any occurrences of `PassWord`, `password`, `pwd`, `onttoken`, `x.X_HW_Token`, `sessionID`, `sid`, `token`, `secret`, and `Cookie` are masked with `[PROTECTED]`.
3. **UI Isolation:**
   - Password fields use `PasswordVisualTransformation`.
   - The diagnostic screen only displays sanitized status flags (`CONNECTED`, `SUCCESS`, `SUPPORTED`). No cookies or private session tokens are ever passed into Compose composables.

---

## 7. Developer Diagnostic Screen & Mock Mode

The UI layer is implemented in Jetpack Compose:
- **Connection Configuration:** Host/IP, Port, Username, Password, Protocol (`AUTO`, `HTTP`, `HTTPS`), and Mock Mode toggle.
- **Developer Safe Diagnostics Card:**
  - Connection State: `CONNECTED`, `CONNECTING`, `DISCONNECTED`, `ERROR`
  - Active Adapter: e.g. `Huawei HG8145C Adapter (V300R015/R017)`
  - Model & Firmware version
  - PON Type: `GPON` / `EPON`
  - Authentication: `SUCCESS`
  - Capabilities Grid: Optical, WiFi, Reboot, Connected Devices, WAN, Ethernet, Traffic
- **Live Telemetry Inspection:**
  - Optical power, voltages, and LOS state
  - WAN IP, gateway, DNS
  - Ethernet LAN1-4 link speeds
  - Connected client list
- **Real-Time Step Console:** Shows progressive connection output (Host validation -> Port probing -> WebUI discovery -> Authentication handshake -> Capability probe).

---

## 8. Project Structure

```
terabyte-network-manager/
├── build.gradle.kts
├── settings.gradle.kts
├── gradle.properties
├── README.md
├── gradle/
│   └── libs.versions.toml
└── app/
    ├── build.gradle.kts
    ├── proguard-rules.pro
    └── src/
        ├── main/
        │   ├── AndroidManifest.xml
        │   ├── java/com/terabyte/networkmanager/
        │   │   ├── TerabyteApp.kt
        │   │   ├── core/
        │   │   │   ├── model/
        │   │   │   │   ├── OntResult.kt
        │   │   │   │   ├── ConnectionConfig.kt
        │   │   │   │   ├── HuaweiAuthResult.kt
        │   │   │   │   ├── HuaweiDeviceInfo.kt
        │   │   │   │   ├── HuaweiCapabilities.kt
        │   │   │   │   ├── HuaweiOpticalInfo.kt
        │   │   │   │   ├── HuaweiWanInfo.kt
        │   │   │   │   ├── HuaweiConnectedDevice.kt
        │   │   │   │   ├── HuaweiEthernetPort.kt
        │   │   │   │   ├── HuaweiWifiInfo.kt
        │   │   │   │   └── HuaweiTrafficStats.kt
        │   │   │   ├── network/
        │   │   │   │   ├── NetworkTransport.kt
        │   │   │   │   ├── HuaweiHttpClient.kt
        │   │   │   │   └── SafeLoggingInterceptor.kt
        │   │   │   ├── security/
        │   │   │   │   ├── KeystoreManager.kt
        │   │   │   │   └── SecureCredentialsManager.kt
        │   │   │   ├── discovery/
        │   │   │   │   ├── HuaweiOntDiscovery.kt
        │   │   │   │   └── DiscoveryResult.kt
        │   │   │   ├── auth/
        │   │   │   │   ├── HuaweiAuthEngine.kt
        │   │   │   │   ├── HuaweiSessionManager.kt
        │   │   │   │   └── AuthType.kt
        │   │   │   ├── parser/
        │   │   │   │   ├── HuaweiJsParserUtils.kt
        │   │   │   │   ├── HuaweiDeviceInfoParser.kt
        │   │   │   │   ├── HuaweiOpticalInfoParser.kt
        │   │   │   │   ├── HuaweiWanParser.kt
        │   │   │   │   ├── HuaweiWifiParser.kt
        │   │   │   │   ├── HuaweiClientParser.kt
        │   │   │   │   ├── HuaweiEthernetParser.kt
        │   │   │   │   └── HuaweiTrafficParser.kt
        │   │   │   ├── adapter/
        │   │   │   │   ├── HuaweiOntClient.kt
        │   │   │   │   ├── BaseHuaweiAdapter.kt
        │   │   │   │   ├── HG8145CAdapter.kt
        │   │   │   │   ├── EG8147X6Adapter.kt
        │   │   │   │   ├── HG8145V5Adapter.kt
        │   │   │   │   ├── EG8145V5Adapter.kt
        │   │   │   │   ├── GenericHuaweiAdapter.kt
        │   │   │   │   ├── MockHuaweiOntClient.kt
        │   │   │   │   └── HuaweiOntClientFactory.kt
        │   │   │   └── repository/
        │   │   │       └── HuaweiOntRepository.kt
        │   │   └── ui/
        │   │       ├── MainActivity.kt
        │   │       ├── theme/
        │   │       │   ├── Color.kt
        │   │       │   ├── Theme.kt
        │   │       │   └── Type.kt
        │   │       └── diagnostic/
        │   │           ├── DiagnosticScreen.kt
        │   │           ├── DiagnosticViewModel.kt
        │   │           └── DiagnosticUiState.kt
        │   └── res/
        │       └── values/
        │           ├── strings.xml
        │           ├── colors.xml
        │           └── themes.xml
        └── test/
            └── java/com/terabyte/networkmanager/
                ├── parser/
                │   ├── HuaweiDeviceInfoParserTest.kt
                │   ├── HuaweiOpticalInfoParserTest.kt
                │   ├── HuaweiWanParserTest.kt
                │   ├── HuaweiClientParserTest.kt
                │   └── HuaweiEthernetParserTest.kt
                ├── auth/
                │   ├── HuaweiAuthEngineTest.kt
                │   └── HuaweiSessionManagerTest.kt
                ├── discovery/
                │   └── HuaweiOntDiscoveryTest.kt
                └── adapter/
                    ├── HuaweiOntClientFactoryTest.kt
                    └── MockHuaweiOntClientTest.kt
```

---

## 9. Verification & Automated Unit Tests

Unit tests are included in `app/src/test/java/com/terabyte/networkmanager/`:
- **`HuaweiDeviceInfoParserTest`**: Verifies HG8145C constructor array parsing, JS variables, and modern EG8147X6 JSON.
- **`HuaweiOpticalInfoParserTest`**: Verifies power parsing (-21.45 dBm), millivolt-to-volt conversions, bias currents, and LOS state handling when fiber is disconnected.
- **`HuaweiWanParserTest`**: Verifies WAN interface names, IPs, gateways, VLAN IDs, and DNS extraction.
- **`HuaweiClientParserTest`**: Verifies client hostname, IP, MAC address, and connection interface type (Ethernet, 2.4G, 5G).
- **`HuaweiEthernetParserTest`**: Verifies LAN1-LAN4 port states and speeds.
- **`HuaweiAuthEngineTest`**: Verifies SHA-256 challenge hashing, single-session concurrency detection (`ErrUserAlreadyLogin`), and session cookie extraction.
- **`HuaweiSessionManagerTest`**: Verifies authentication state, automatic session maintenance, and secure logout.
- **`HuaweiOntDiscoveryTest`**: Verifies IP validation, protocol probing, and login page extraction.
- **`HuaweiOntClientFactoryTest`**: Verifies that adapter dispatch evaluates Model + Firmware + Capabilities.
- **`MockHuaweiOntClientTest`**: Verifies offline mock telemetry and state transitions.
