# BlackHoleMonitorApp

A macOS menu bar app for audio routing, monitoring, and processing using BlackHole virtual audio driver.

## Features

- **Audio Routing**: Route audio from BlackHole to any output device
- **Real-time Spectrum Analyzer**: 16-band FFT visualization (32Hz-16kHz)
- **8-Band Equalizer**: Biquad peak filters at 60, 120, 250, 500, 1k, 2k, 4k, 8k Hz
- **Compressor**: Block-based processing with attack/release, threshold, ratio, makeup gain
- **Karaoke Mode**: Vocal removal via Mid-Side processing or AI (Demucs)
- **Disco Mode**: Fullscreen audio-reactive visualizations with lasers, aurora, particles
- **Auto-Reconnect**: Automatically restarts audio when USB devices are reconnected
- **Sample Rate Matching**: Warning when resampling is active, supports 44.1kHz and 48kHz

## Requirements

- macOS 13.0+
- [BlackHole](https://github.com/ExistentialAudio/BlackHole) virtual audio driver
- For AI Karaoke: Python 3 with Demucs (`pip install demucs`). The app picks the first
  `python3` that can import `demucs`; override with
  `defaults write com.blackhole.monitor demucsPythonPath /path/to/python3`

## Building

```bash
./build.sh
```

The app will be built to `build/BlackHoleMonitorApp.app` (arm64 by default,
`ARCHS="arm64 x86_64" ./build.sh` for a universal binary).

## Tests

```bash
swift test                     # XCTest suite for the real-time DSP code
swift test --sanitize=thread   # same, under Thread Sanitizer
```

## Logs

```bash
log stream --level info --predicate 'subsystem == "com.blackhole.monitor"'
```

## Installation

```bash
cp -R build/BlackHoleMonitorApp.app /Applications/
```

## Usage

1. Set your system audio output to **BlackHole**
2. Launch **BlackHoleMonitorApp** from Applications
3. Select your actual output device (speakers/headphones)
4. Click **Start**

## Architecture

```
Audio Source → BlackHole → BlackHoleMonitorApp → Output Device
                               ├── Karaoke (vocal removal)
                               ├── Compressor
                               ├── 8-Band EQ
                               ├── Spectrum Analyzer
                               └── Disco Mode visuals
```

## Audio Processing Pipeline

1. **Input**: Capture from BlackHole via AUHAL (interleaved or planar)
2. **Resampling**: Streaming Catmull-Rom resampler with drift correction (if rates differ)
3. **Ring buffer**: 30 ms target, grows automatically after underruns (CPU overload)
4. **Karaoke**: Mid-Side processing or Demucs AI (~4 s latency)
5. **Compression**: Block-based peak compressor
6. **EQ**: 8 biquad peak filters
7. **Output**: Route to selected output device

Audio callbacks never allocate, log or block; settings reach them through
lock-free-for-the-reader mailboxes. See `docs/ARCHITECTURE.md`.

## Files

- `BlackHoleMonitorApp.swift` - App delegate, menu bar, Background Music volume sync
- `AudioManager.swift` - Settings, devices, session lifecycle (main thread)
- `AudioSession.swift` - CoreAudio units and real-time render callbacks
- `VocalSeparatorAI.swift` - Demucs server launcher and client
- `DSP/` - Real-time processing (ring buffer, resampler, compressor, EQ, karaoke, spectrum, Demucs protocol), unit tested
- `MenuBarView.swift`, `SpectrumAnalyzerView.swift`, `OscilloscopeView.swift`, `DiscoView.swift` - UI
- `ML/demucs_server.py` - Python server for Demucs vocal separation

## License

MIT License
