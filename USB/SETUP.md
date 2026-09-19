# FacePull: Windows USB and OBS setup

## One time

1. Install **Apple Devices** from the Microsoft Store. Connect your iPhone 13 Pro with a Lightning **data** cable, unlock it, open Apple Devices, and tap **Trust** on the phone.
2. Keep this USB folder together. Right-click `Setup-USB.ps1` → **Run with PowerShell**, or run `powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup-USB.ps1` from this folder. It copies the bridge into your Windows user profile and adds automatic startup at login. No Python or iproxy download is needed.
3. Install the updated FacePull build. Choose **High · 1280 × 720 · 30 fps** as a starting point and tap the shutter to start streaming.
4. In **Settings → Connect**, copy **USB · H.264**. It looks like `rtsp://127.0.0.1:18554/facepull?token=YOUR_SAVED_KEY`. The key persists across app launches and stream restarts; removing app data can change it.
5. In OBS add **Media Source**, uncheck **Local File**, and paste the complete URL into **Input**. Set **Network Buffering** to **0 MB**. Set **Input Format** to `rtsp` and **FFmpeg Options** to `rtsp_transport=tcp fflags=nobuffer` if those fields are available. Keep hardware decoding enabled on the tested PC. Enable restart when the source becomes active. Save the source. Video has no audio; add your microphone separately. Zero network buffering does not disable all decoder/display queues.

## Each session

Plug in the iPhone, open FacePull, and start streaming. Leave FacePull in the foreground. Its OLED saver can black out the app while streaming continues; do not lock the phone with its side button. The bridge stays running and accepts new connections after cable reconnection. Automatic OBS recovery after an actual cable disconnect still needs on-device testing.

## Wi-Fi

Use the complete **Wi-Fi · H.264** URL from Settings → Connect in a second saved OBS Media Source, also with **Network Buffering 0 MB**. This uses the iPhone IP and port 8554 directly. Keep phone and PC on the same LAN. For an unchanged iPhone IP, make a DHCP reservation in your router and keep the phone's private Wi-Fi address fixed for that network. The app cannot assign router addresses. A bare IP without the port, path, and saved access key is not a media URL.

Save USB and Wi-Fi sources once; enable the one you need. USB H.264 uses `127.0.0.1:18554`; the browser remote page uses `127.0.0.1:18080`. Wi-Fi uses the reserved iPhone IP. Both H.264 sources use the same saved stream key.

## Remote control

While FacePull is streaming, open `http://127.0.0.1:18080/remote` for USB, or `http://IPHONE_IP:8080/remote` for Wi-Fi. Enter the separate **Remote password** from Settings → Connect. Adjust lens, tracking, subject mode, exposure, white balance, backgrounds, and presets. Quality stays fixed while live. Remote control also works while OLED saver is black. Keep the service on your local network.

## Troubleshooting

- Confirm the phone appears in Apple Devices and trusts the computer.
- Start streaming before enabling the OBS source.
- Run `Start-USB.ps1` if needed. Only one bridge owns the local port.
- Try the USB remote page at `http://127.0.0.1:18080/remote` to check the browser control route. A 503 response means the bridge is running but cannot connect to the phone/app yet. The RTSP port closes an unavailable connection instead of returning HTTP.
- Use one connected iPhone, or start the bridge with `-DeviceID` and the phone's UDID.
- Apple's Mobile Device service was not found on this PC during development. Install/repair Apple's device support if USB is unavailable.

## iPhone 13 Pro

FacePull supports iOS 17+; native Liquid Glass needs iOS 26, which iPhone 13 Pro supports. Heat can reduce FPS. Start with High/720p for tracking plus portrait blur. Subject lock is visual tracking, not identity recognition. Put yourself clearly in frame and tap **Lock me** again to reacquire if necessary. Auto widen fits detected faces as far as the camera's field of view allows.

## Backgrounds and presets

Custom opens a library without changing the background. Select an image or choose Photos. Long-press a thumbnail to favorite or remove it. Clear recents removes the recent-history entries; favorites, the active background, and saved presets stay. Presets save the lens, camera adjustments, tracking mode, background selection, mirroring, grid, and OLED setting. Loading a preset while live preserves the current quality.

## Disable startup

Open `shell:startup` in Windows and remove **FacePull USB**. Restart Windows to stop the existing bridge. Installed files are in `%LOCALAPPDATA%\FacePull\USB`.

References: [OBS Media Sources](https://obsproject.com/kb/media-sources), [Apple iOS compatibility](https://support.apple.com/guide/iphone/iphe3fa5df43/ios), [usbmux protocol](https://github.com/libimobiledevice/libusbmuxd), [Windows device-service prerequisites](https://doronz88.github.io/pymobiledevice3/guides/troubleshooting/).

## Measure a delayed stream

With the phone streaming, run from this folder:

```powershell
$streamURL = Read-Host 'Paste the full FacePull RTSP URL'
powershell -NoProfile -ExecutionPolicy Bypass -File .\Measure-Stream.ps1 -Url $streamURL -DurationSeconds 15
```

The report includes received FPS, startup time, keyframes, sequence gaps and
additional arrival delay. It excludes the URL/key and camera images. Measure once
with OBS disconnected, then again with OBS connected at the same quality. The probe
itself adds one viewer and therefore network load. Repeat over USB if available.

Increasing arrival delay indicates accumulating delay before the probe receives
the video. A low value does **not** exclude a fixed network delay or latency before
encoding. This is not glass-to-glass latency: film a visible millisecond timer and
the OBS display together to measure that. See `../LATENCY-TESTS.md`.

