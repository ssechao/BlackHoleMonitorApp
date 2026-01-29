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
- For AI Karaoke: Python 3 with Demucs (`pip install demucs`)

## Building

```bash
./build.sh
```

The app will be built to `build/BlackHoleMonitorApp.app`

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

1. **Input**: Capture from BlackHole via AudioUnit
2. **Resampling**: VDSPResampler with cubic Hermite interpolation (if needed)
3. **Karaoke**: Mid-Side processing or Demucs AI
4. **Compression**: Optimized block-based compressor with pre-allocated buffers
5. **EQ**: 8 biquad peak filters with anti-denormal protection
6. **Output**: Route to selected output device

## Files

- `BlackHoleMonitorApp.swift` - Main app and menu bar
- `AudioManager.swift` - Core audio routing and processing
- `MenuBarView.swift` - SwiftUI interface
- `OptimizedAudioProcessing.swift` - TDD-tested compressor and drift controller
- `VocalSeparatorAI.swift` - Demucs integration for AI vocal removal
- `SpectrumAnalyzerView.swift` - FFT visualization
- `DiscoView.swift` - Audio-reactive fullscreen effects
- `ML/demucs_server.py` - Python server for Demucs vocal separation

## License

MIT License
