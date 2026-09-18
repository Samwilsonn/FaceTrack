# iPhone acceptance checks

These checks have not been completed by the coding agent. They require your device.

| Check | Expected result |
| --- | --- |
| Fresh install; deny camera | Clear error and Open Settings action; no crash |
| Grant camera, return to app | Live preview starts |
| Start/stop/restart stream | OBS reconnects using the saved H.264 RTSP URL and access key |
| H.264 Wi-Fi source | 30-minute OBS Media Source test at each quality, with actual dimensions, FPS, latency, and dropped frames recorded |
| H.264 USB source | With Wi-Fi disabled, OBS receives video from the saved loopback RTSP URL |
| Hardware encoder | VideoToolbox reports hardware use on iPhone 13 Pro; record heat and battery drain during H.264 streaming |
| Switch front/rear and physical lenses | Preview and OBS recover; exposure controls remain usable |
| Rotate phone in both output formats | Upright frame, fixed selected dimensions, no stretch |
| Mirror settings with visible printed text | Preview and stream follow their separate settings |
| Move face to all four image edges | No black crop edges or out-of-bounds jumps |
| Two people; reorder positions | Verify position-based target choice is suitable |
| Leave frame for more than a second | View widens smoothly |
| Blur and custom image | Subject remains visible; preview matches OBS |
| Pick a large/rotated photo, cancel picker | Photo orientation correct; cancel leaves app usable |
| Clear Custom recents | History disappears; active background, favorites, and saved-preset backgrounds remain usable |
| Slow client or disconnected Wi-Fi | No accumulating frame queue; viewer count clears |
| Connect multiple viewers | Viewer count follows active RTSP clients and streaming stays responsive |
| Dim and wake | Stream continues; original brightness returns |
| Lock phone or background app | Stream stops; return and start manually |
| Camera interrupted by call/another app | No crash; retry or foreground restores preview |
| Unplug/reconnect USB | Bridge restores forwarding and OBS source recovers without editing its URL |
| Two-iPhone pairing | Remote discovers Host, rejects a wrong code, accepts the correct code, and reconnects after both apps restart |
| Remote controls | Host applies lens, quality, exposure, tracking, background, preset, and stream changes; Remote shows confirmed state; Live Preview defaults OFF |
| Mic hot-toggle | Start with mic OFF; toggle ON/OFF/ON without restarting OBS. Audio follows each toggle; video never blanks or restarts |
| A/V latency comparison | Same quality, connection, OBS source settings: film a visible millisecond timer and a clap with mic OFF, then ON. Record video delay and lip-sync; audio must not add the previous ~1 second |
| Optional Remote preview | ON shows final framing, exposure, mirror and background, with/without OBS connected. OFF stops preview transport and rendering. Compare OBS latency/FPS with preview OFF/ON |
| Preview lifecycle | Toggle 20 times, background/return Remote, leave Remote screen, stop/restart Host stream, disconnect/reconnect Wi-Fi. No stale frames, stuck decoder, control lag or steadily growing memory |
| FaceTrack submenu | On Host and Remote, Lock me and Auto widen keep the submenu open; outside tap still dismisses it |
| Audio/reconnect recovery | Repeat OBS Properties OK/reconnect with mic ON and OFF; no AAC format error, blank video or accumulating initial lag |
| Installed app icon | A fresh install shows the full motif at Home Screen and Settings sizes |
| 30-minute stream with effects | Record FPS, heat, memory, latency, and battery drain |

Do not mark these passed on the strength of a successful compile alone.

