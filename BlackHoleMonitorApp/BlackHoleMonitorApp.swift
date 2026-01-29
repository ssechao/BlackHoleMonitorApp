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
    var volumeListenerID: AudioObjectPropertyListenerBlock?
    var bgmDeviceID: AudioDeviceID = 0

    private func debugLog(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: "/tmp/bhm_app.log") {
                if let h = FileHandle(forWritingAtPath: "/tmp/bhm_app.log") {
                    h.seekToEndOfFile()
                    h.write(data)
                    h.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: "/tmp/bhm_app.log", contents: data)
            }
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLog("App launched")
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "BlackHole Monitor")
            button.action = #selector(togglePopover)
            debugLog("Status item created")
        }

        popover = NSPopover()
        popover?.contentSize = NSSize(width: 300, height: 650)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(rootView: MenuBarView())
        debugLog("Popover created")
        
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
    }
    
    // MARK: - Background Music Volume Listener
    
    func findBGMDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        guard status == noErr else { return nil }
        
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs)
        guard status == noErr else { return nil }
        
        for deviceID in deviceIDs {
            if let name = getDeviceName(deviceID), name.lowercased().contains("background music") {
                return deviceID
            }
        }
        return nil
    }
    
    func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &name)
        guard status == noErr else { return nil }
        return name as String
    }
    
    func setupBGMVolumeListener() {
        guard let deviceID = findBGMDevice() else {
            debugLog("Background Music device not found")
            return
        }
        
        bgmDeviceID = deviceID
        debugLog("Found Background Music device: \(deviceID)")
        
        // Get initial volume
        if let volume = getBGMVolume() {
            debugLog("Initial BGM volume: \(volume)")
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
        
        let listener: AudioObjectPropertyListenerBlock = { [weak self] (numberAddresses, addresses) in
            guard let self = self else { return }
            if let volume = self.getBGMVolume() {
                self.debugLog("BGM volume changed: \(volume)")
                DispatchQueue.main.async {
                    self.audioManager.volume = volume
                }
            }
        }
        
        volumeListenerID = listener
        
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener)
        if status == noErr {
            debugLog("BGM volume listener added")
        } else {
            debugLog("Failed to add BGM volume listener: \(status)")
            
            // Try master element
            address.mElement = 0
            let status2 = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener)
            if status2 == noErr {
                debugLog("BGM volume listener added (master element)")
            } else {
                debugLog("Failed to add BGM volume listener (master): \(status2)")
            }
        }
        
        // Also listen for mute changes
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let muteListener: AudioObjectPropertyListenerBlock = { [weak self] (numberAddresses, addresses) in
            guard let self = self else { return }
            if let muted = self.getBGMMute() {
                self.debugLog("BGM mute changed: \(muted)")
                DispatchQueue.main.async {
                    if muted {
                        self.audioManager.previousVolume = self.audioManager.volume
                        self.audioManager.volume = 0
                    } else if self.audioManager.volume == 0 {
                        self.audioManager.volume = self.audioManager.previousVolume > 0 ? self.audioManager.previousVolume : 0.5
                    }
                }
            }
        }
        
        AudioObjectAddPropertyListenerBlock(deviceID, &muteAddress, DispatchQueue.main, muteListener)
    }
    
    func removeBGMVolumeListener() {
        guard bgmDeviceID != 0 else { return }
        
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        if let listener = volumeListenerID {
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
            // Try master element
            address.mElement = 0
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
        debugLog("Popover closed")
    }

    @objc func togglePopover() {
        debugLog("togglePopover called")
        if let button = statusItem?.button {
            if popover?.isShown == true {
                debugLog("Closing popover")
                popover?.performClose(nil)
            } else {
                debugLog("Showing popover")
                NSApp.activate(ignoringOtherApps: true)
                popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                popover?.contentViewController?.view.window?.makeKey()
            }
        }
    }
}
