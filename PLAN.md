# NAM2Nano — macOS Development Plan (Swift + SwiftUI + C++ DSP)

> **Status (2026-11-25):** Phases 0–4 implemented. Code written on Linux: the C++ engine is compiled
> and tested offline, the Swift/SwiftUI app has **not been compiled yet** (needs Xcode on macOS).
> Phase 5 (hardware testing) is open. See [§6 Implementation status](#6-implementation-status).

---

## 1. Project Goal
**NAM2Nano** is a native macOS utility (SwiftUI, minimum target macOS 14.0 Sonoma, no App Sandbox)
that automates re-capturing **Neural Amp Modeler (`.nam`)** models into the **Neural DSP Nano
Cortex**, with no DAW, external plugins or third-party audio interfaces.

### Audio flow without an external interface (self-loopback on the Nano Cortex)
The Nano Cortex acts both as the USB-C audio interface and as the capture unit:
1. The Mac detects the `"Nano Cortex"` CoreAudio device over USB-C.
2. During the capture the **Nano plays its own capture test signal on OUTPUT 2R (CAPTURE OUT)**.
   That signal reaches the Mac on the processed USB input (default **USB In 4**), runs in real time
   through `NeuralAmpModelerCore` loaded with the chosen `.nam`, and goes back out on the USB output
   that feeds the physical **`OUT 1L`** jack (default **USB Out 1**).
   *(The original plan assumed the Mac generated the signal; the Nano's capture design means the
   test signal comes from the pedal.)*
3. A **single short TS patch cable** connects **`OUT 1L` → `CAPTURE IN`** on the Nano Cortex.
4. Remote control (capture mode, CAPTURE IN calibration, progress monitoring, save with metadata)
   runs over **Bluetooth Low Energy (CoreBluetooth)**.

```
Nano OUTPUT 2R (CAPTURE OUT) ──USB In 4──▶ Mac: NAM ──USB Out 1──▶ OUTPUT 1L ──cable──▶ CAPTURE IN
```

---

## 2. Technical Architecture & Stack

* **UI & app lifecycle:** Swift 5.9+ (Swift 5 language mode), SwiftUI (macOS 14+), `@Observable`
  state machine (`AppState`). Project generated with **XcodeGen** (`project.yml`).
* **Bluetooth Low Energy:** `CoreBluetooth`, protocol from the community reverse-engineering in
  [`DrD85/nano-cortex-editor`](https://github.com/DrD85/nano-cortex-editor):
  * GATT service `A002` (`A003` fallback), write characteristic `C304` (with response), notify `C305`.
  * Framing `[len][0xC0][protobuf payload][u32 LE type]`; long replies split with flags `0x40`
    (first) / `0x80` (last).
  * Messages used: state request/response (1/2, firmware in field 24, capture mode in field 23),
    enter capture mode (73), CAPTURE IN / OUTPUT value (26), start training (39), progress (40),
    done (41), capture state (87/88), sanity (93), button/exit (27), meters (64),
    save capture (13/14), set capture slot (80/81), preset-change ack (29/30).
  * `grliszas14/NanoDesk` has no public source (only a releases repo), so it was not used.
* **Audio engine:** direct **AUHAL** (`kAudioUnitSubType_HALOutput`) in full duplex on the Nano
  (single device clock, no drift), fixed **48 kHz**, Float32 non-interleaved. The render callback
  touches only raw pointers (no ARC, no allocation) and calls into C++.
* **DSP engine (NAM):** `NeuralAmpModelerCore` (pinned commit `d3189ed`, v0.6) via an Objective-C++
  bridge, built with `NAM_SAMPLE_FLOAT` and `NAM_ENABLE_A2_FAST`:
  * **WaveNet**, **LSTM**, **ConvNet** (A1), **A2-Full / A2-Lite**, A2 feature-set WaveNets,
    **SlimmableContainer**, **Sequential**, **Linear** (IR).
  * Models not at 48 kHz (44.1 / 96 kHz) are resampled in real time by a dedicated **C++
    windowed-sinc resampler** (replaces `AVAudioConverter`, which is not guaranteed RT-safe).
  * Automatic gain staging from `input_level_dbu` / `loudness`, plus CAPTURE IN auto-level over BLE
    to avoid clipping.
  * Lock-free model hot-swap (atomic pending/retired pointers; models are freed off the audio thread).
* **Step graphics:** native SwiftUI `Canvas` + `TimelineView` drawing the Nano Cortex, the USB-C
  cable, the two footswitches for BLE pairing and the `OUT 1L → CAPTURE IN` cable, with live state.

---

## 3. User Experience: Guided Step Wizard

Single fixed-size window (860×640 pt), 6-step indicator at the top, and a `Continue` button that is
enabled **only once the current step's hardware/software check passes**. The footer shows live
USB/BLE/cable status plus DSP load and XRUN count.

### Step 1: USB-C connection ✅
* Vector diagram: Mac ↔ Nano USB-C cable (animated while waiting) and status LED.
* Real-time check: `AudioObjectAddPropertyListenerBlock(kAudioHardwarePropertyDevices)`, device
  matched by name, forced to 48 kHz, AUHAL started (mic permission requested here).
* Feedback: `"Nano Cortex detected over USB (48 kHz)"` plus device, channel and buffer info.

### Step 2: Bluetooth (BLE) connection ✅
* Vector diagram: both footswitches pulsing with "HOLD BOTH" hints.
* Scan (name matches `/nano|cortex/i`, or already-connected peripherals with A002/A003), auto-connect,
  GATT discovery, notifications, state request → firmware version.
* Feedback: `"Connected over Bluetooth (Firmware vX.X.X)"`.

### Step 3: Audio cabling (`OUT 1L` → `CAPTURE IN`) ✅
* Vector diagram: animated patch cable (orange → green when verified, red on failure, signal dots
  while testing).
* Continuity & level check (`SignalCalibrator`): enter capture mode → measure CAPTURE IN noise floor
  via BLE meters (message 64) → 1 kHz pilot tone on OUT 1L → measure rise → stop tone and verify the
  level decays (**feedback-loop detection**) → exit capture mode.
* Feedback: `"Audio loop verified"`, with a **"Skip check"** option.

### Step 4: `.nam` selection & analysis ✅
* Drag & drop area + `Choose file…`.
* Parser (`NAMParser`, no audio thread involved): name, architecture, **A1 (Standard/Lite/Feather/
  Nano/Custom) vs A2 (A2-Full / A2-Lite / A2 feature set)** detection mirroring NAM Core's
  `is_a2_shape`, Slimmable flag, sample rate (resampling warning), file version, parameter count,
  `input_level_dbu` / `output_level_dbu` / `loudness` / `gain`, validation ESR, author / gear / date.
* Digital gain pre-calibration: input trim (USB dBu reference − `input_level_dbu`) and output trim
  (normalised to target loudness), with estimated peak.
* The model is then loaded and prewarmed off the audio thread; `Continue` unlocks once it is ready.

### Step 5: Capture metadata ✅
* **Capture name** (prefilled from the `.nam`; 4–32 characters).
* **Device type** tiles: Amp Head, Amp + Cab, Combo, Pedal / Overdrive, Preamp, Cab → mapped to the
  firmware's types `amp_head` / `amp_and_cab` / `cab` / `pedal`.
* **Gain / Drive** (Clean / Crunch / High Gain + 1–10 slider) and **notes**: the Nano protocol has no
  field for these, so they go to the local history (`~/Library/Application Support/NAM2Nano/history.json`).
* **Destination:** Capture Library only, or Library + slot 1–1 … 5–5.

### Step 6: Capture & save ✅
* Ready screen: `.nam` file, architecture, capture name, routing, live meters (Mac input/output in
  dBFS, Nano CAPTURE IN / OUTPUT raw meters), DSP load, XRUN / overload / clip counters.
* `Start Capture`: enter capture mode → CAPTURE IN auto-level (pink noise through the model, binary
  search on the BLE gain until peaks sit at 165–215/255) → start training with the model in the loop.
* Progress bar driven by BLE progress (0–255). The stage labels (*Calibration → Profiling → Neural
  network training → Finalizing*) are approximate: the Nano reports a single value.
* Safety: sanity messages (signal too low/hot), EXIT on the pedal, BLE loss, 12-minute timeout;
  automatic source-channel detection if USB In 4 stays silent.
* Completion: save with name/type → optional slot assignment → back to play mode → confirmation
  screen with **"Capture another .nam file"** (back to step 4, keeping USB, BLE and cable verified)
  or **"Quit"**.

---

## 4. Project Folder Structure (as implemented)

```text
NAM2Nano/
├── project.yml                         # XcodeGen spec
├── Scripts/bootstrap.sh                # fetches NeuralAmpModelerCore + Eigen, generates the project
├── Tools/
│   ├── generate_icon.py                # app icon generator (Pillow)
│   └── engine_test/                    # offline C++ engine tests (macOS/Linux)
└── NAM2Nano/
    ├── NAM2Nano-Bridging-Header.h
    ├── App/
    │   ├── NAM2NanoApp.swift           # entry point, main window, Debug menu, Settings
    │   ├── AppState.swift              # wizard state machine
    │   └── AppSettings.swift           # routing/calibration settings (UserDefaults)
    ├── Core/
    │   ├── Audio/
    │   │   ├── AudioDeviceMonitor.swift  # CoreAudio device detection, 48 kHz, buffer size
    │   │   ├── NanoAudioEngine.swift     # AUHAL full duplex, RT render callback, meters
    │   │   └── SignalCalibrator.swift    # cable test, CAPTURE IN auto-level, gain staging
    │   ├── Bluetooth/
    │   │   ├── NanoBLEManager.swift      # CoreBluetooth, write queue, events, debug log
    │   │   └── NanoBLEProtocol.swift     # UUIDs, framing, protobuf, commands, event decoding
    │   ├── Capture/
    │   │   └── CaptureSession.swift      # step 6 orchestration + local history
    │   └── NAM/
    │       ├── NAMParser.swift
    │       ├── NAMProcessorBridge.h/.mm  # Obj-C++ facade
    │       ├── Engine/
    │       │   ├── NAMEngine.hpp/.cpp        # RT engine, lock-free model swap
    │       │   ├── StreamingResampler.hpp    # windowed-sinc resampler
    │       │   └── SignalGenerators.hpp      # sine + pink noise
    │       └── ThirdParty/NeuralAmpModelerCore/  # fetched by bootstrap.sh (git-ignored)
    ├── Models/
    │   ├── NAMModelInfo.swift
    │   └── NanoCaptureMetadata.swift
    ├── Views/
    │   ├── WizardContainerView.swift
    │   ├── SettingsView.swift
    │   ├── Steps/Step1USBView … Step6CaptureView.swift
    │   ├── Components/NanoDiagramView, LevelMeterView, StatusBadge.swift
    │   └── Debug/BLEMonitorView.swift  # BLE monitor + USB audio monitor
    └── Resources/
        ├── Assets.xcassets             # AppIcon (Phase 0) + AccentColor
        ├── Info.plist
        └── NAM2Nano.entitlements
```

---

## 5. Phased Implementation Plan

### Phase 0 — App icon ✅
1. Proposed 4 concepts; the user chose "Neural Jack", then simplified it to **the neural network
   only**: a flat 1→3→1 network, orange→violet→cyan gradient, graphite squircle.
2. Generated by `Tools/generate_icon.py` at 1024 px plus all macOS sizes in
   `Assets.xcassets/AppIcon.appiconset`.

### Phase 1 — Scaffolding & `NeuralAmpModelerCore` integration ✅
1. XcodeGen project (`NAM2Nano`, SwiftUI, macOS 14.0+, no App Sandbox, hardened runtime with
   audio-input). The NAM core is fetched by `bootstrap.sh` (pinned commit), not vendored.
2. `NAMProcessorBridge` (Obj-C++) over a pure C++ `nam2nano::Engine`; all allocation and prewarm
   happen off the real-time thread.
3. `NAMParser.swift`: name, architecture, A1 vs A2, sample rate, calibration levels, metadata.

### Phase 2 — CoreAudio engine & loopback calibration ✅
1. `NanoAudioEngine.swift`: AUHAL full duplex at 48 kHz on the Nano, configurable source/output
   channels, per-channel input meters, HAL overload listener.
2. `SignalCalibrator.swift`: cable continuity + feedback test (step 3), CAPTURE IN auto-level and
   gain staging (steps 4/6).

### Phase 3 — Nano Cortex BLE protocol ✅ (unverified on hardware)
1. `NanoBLEManager.swift` / `NanoBLEProtocol.swift` built from `DrD85/nano-cortex-editor`.
2. **Debug → BLE Monitor** (⌘⇧B): packet log, meter logging toggle, filter, copy, raw hex sender,
   quick commands. **Debug → USB Audio Monitor** (⌘⇧A): per-channel USB input levels.

### Phase 4 — 6-step wizard UI & vector illustrations ✅
1. `NanoDiagramView.swift`: animated USB, two-footswitch pairing and `OUT 1L → CAPTURE IN` cabling.
2. All 6 screens wired to `AppState`, including "Capture another .nam file", which skips the
   already-verified hardware steps.

### Phase 5 — End-to-end testing & polish ⏳
1. Compile in Xcode and fix any build errors (the Swift code has never been compiled).
2. Check for allocations on the audio thread (Instruments / Time Profiler). The C++ engine is
   already verified offline (see §6).
3. Run a real capture on a Nano Cortex and check tonal fidelity against the original `.nam`.
4. Confirm or adjust the hardware assumptions listed in §6.

---

## 6. Implementation status

### Verified offline (Linux, `Tools/engine_test`)
* Resampler 48k → 44.1k → 48k and 48k → 96k → 48k: 0.000 dB gain error, SNR 93.7 / 84.8 dB,
  constant 256-frame output per block, latency ≈ 33 / 24 samples.
* All NAM Core example models load and process 10 s in real time with zero underruns: A1 Standard,
  A2 (SlimmableContainer, A2-Full), LSTM, Slimmable LSTM container, A2 feature test, condition DSP,
  and 44.1 kHz / 96 kHz variants through the resampling path.
* Model hot-swap during rendering: clean under ThreadSanitizer.
* Parser A1/A2 classification checked against the example models.

### Deviations from the original plan
| Plan | Implementation | Reason |
|---|---|---|
| Mac generates/routes the test signal | Nano plays it on OUTPUT 2R; Mac processes USB In 4 | the Nano capture design |
| Hand-made Xcode project | XcodeGen `project.yml` | a `.pbxproj` written without Xcode is fragile |
| NAM core in repo | fetched by `Scripts/bootstrap.sh` (pinned) | keeps the repo small |
| `AVAudioConverter` resampling | C++ windowed-sinc resampler | real-time safety |
| `RingBuffer.swift` (SPSC) | atomics in the C++ engine; FIFO used only on the audio thread | no cross-thread audio queue needed |
| `AVAudioEngine` | direct AUHAL | one duplex unit on one device, lower latency |
| Gain level / notes written to the Nano | kept in local history | no such fields in the protocol |
| Device types Amp Head/Amp+Cab/Combo/Pedal/Preamp | mapped to `amp_head`/`amp_and_cab`/`cab`/`pedal` | firmware types |
| 4 progress phases from the Nano | approximate labels on one 0–255 progress value | protocol limitation |
| — (added) | `AppSettings`, `CaptureSession`, `AudioDeviceMonitor`, Settings window, USB Audio Monitor | needed for routing and flow |

### Open points (need real hardware)
1. **BLE capture messages** were decoded from Cortex Cloud traffic and are not confirmed on a Nano.
   The advertised BLE name is unknown.
2. **USB channel layout:** Neural DSP says 4 in / 3 out, other sources say 8. Confirm that the
   capture test signal is on In 4 and that USB playback reaches OUTPUT 1L in capture mode.
3. **Feedback risk** if OUTPUT 1L monitors CAPTURE IN in capture mode (detected by the step 3 test).
4. **USB dBu reference** for input calibration is an assumption (12 dBu, editable in Settings).
5. **Capture name limit:** 4–32 characters, the maximum is a conservative guess.
6. **Round-trip latency** through the Mac (USB in + out + buffer) is assumed to be absorbed by the
   Nano's capture alignment.
