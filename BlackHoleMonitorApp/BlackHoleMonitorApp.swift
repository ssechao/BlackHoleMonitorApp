import SwiftUI
import AVFoundation
import CoreAudio
import AudioToolbox
import ServiceManagement

@main
struct BlackHoleMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var audioManager = AudioManager.shared
    var volumeListener: AudioObjectPropertyListenerBlock?
    var volumeListenerElement: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    var muteListener: AudioObjectPropertyListenerBlock?
    var bgmDeviceID: AudioDeviceID = 0
    private let log = Log.app

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("App launched")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "BlackHole Monitor")
            button.action = #selector(togglePopover)
        }

        popover = NSPopover()
        popover?.contentSize = NSSize(width: 300, height: 650)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(rootView: MenuBarView())

        // Monitor for popover close
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(popoverDidClose),
            name: NSPopover.didCloseNotification,
            object: popover
        )

        // Setup volume listener on Background Music device
        setupBGMVolumeListener()
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeBGMVolumeListener()
        audioManager.shutdown()
    }

    // MARK: - Background Music Volume Listener

    func setupBGMVolumeListener() {
        guard let deviceID = AudioDevices.find(nameContaining: "background music") else {
            log.info("Background Music device not found")
            return
        }

        bgmDeviceID = deviceID
        log.info("Found Background Music device: \(deviceID)")

        // Get initial volume
        if let volume = getBGMVolume() {
            log.info("Initial BGM volume: \(volume)")
            DispatchQueue.main.async {
                self.audioManager.volume = volume
            }
        }

        // Listen for volume changes
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let volume = self.getBGMVolume() else { return }
            self.audioManager.volume = volume
        }

        var status = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener)
        if status != noErr {
            log.error("Failed to add BGM volume listener: \(status), trying channel 1")
            address.mElement = 1
            status = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener)
        }
        if status == noErr {
            volumeListener = listener
            volumeListenerElement = address.mElement
        } else {
            log.error("Failed to add BGM volume listener: \(status)")
        }

        // Also listen for mute changes
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let muteListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let muted = self.getBGMMute() else { return }
            let manager = self.audioManager
            if muted {
                manager.previousVolume = manager.volume
                manager.volume = 0
            } else if manager.volume == 0 {
                manager.volume = manager.previousVolume > 0 ? manager.previousVolume : 0.5
            }
        }

        if AudioObjectAddPropertyListenerBlock(deviceID, &muteAddress, DispatchQueue.main, muteListener) == noErr {
            self.muteListener = muteListener
        }
    }

    func removeBGMVolumeListener() {
        guard bgmDeviceID != 0 else { return }

        if let listener = volumeListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: volumeListenerElement
            )
            AudioObjectRemovePropertyListenerBlock(bgmDeviceID, &address, DispatchQueue.main, listener)
        }
        if let listener = muteListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(bgmDeviceID, &address, DispatchQueue.main, listener)
        }
    }

    func getBGMVolume() -> Float? {
        guard bgmDeviceID != 0 else { return nil }
        
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var volume: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        
        var status = AudioObjectGetPropertyData(bgmDeviceID, &address, 0, nil, &dataSize, &volume)
        if status != noErr {
            // Some drivers only expose per-channel volume
            address.mElement = 1
            status = AudioObjectGetPropertyData(bgmDeviceID, &address, 0, nil, &dataSize, &volume)
        }
        
        return status == noErr ? volume : nil
    }
    
    func getBGMMute() -> Bool? {
        guard bgmDeviceID != 0 else { return nil }
        
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var muted: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(bgmDeviceID, &address, 0, nil, &dataSize, &muted)
        
        return status == noErr ? (muted != 0) : nil
    }
    
    @objc func popoverDidClose(_ notification: Notification) {
        // Disable visualization updates when popover is closed to save CPU
        // (only disable if floating spectrum window is also closed)
        if !SpectrumWindowController.shared.isActive && !DiscoWindowController.shared.isActive {
            audioManager.visualizationActive = false
        }
    }

    @objc func togglePopover() {
        if let button = statusItem?.button {
            if popover?.isShown == true {
                popover?.performClose(nil)
            } else {
                // Re-enable visualization updates when popover opens
                audioManager.visualizationActive = true
                NSApp.activate(ignoringOtherApps: true)
                popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                popover?.contentViewController?.view.window?.makeKey()
            }
        }
    }
}
