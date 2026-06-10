import AudioToolbox
import CoreAudio
import Foundation
import os

enum ProcessTapError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case noOutputDevice
    case aggregateCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let status):
            return "Failed to create process tap (\(status)). Check that dB has System Audio Recording permission."
        case .noOutputDevice:
            return "No default output device found."
        case .aggregateCreationFailed(let status):
            return "Failed to create aggregate device (\(status))."
        case .ioProcCreationFailed(let status):
            return "Failed to create audio IO proc (\(status))."
        case .deviceStartFailed(let status):
            return "Failed to start audio device (\(status))."
        }
    }
}

/// Taps the audio of a set of processes, mutes their direct output, and
/// re-renders the tapped audio to the default output device with a gain applied.
final class ProcessTap {
    private static let logger = Logger(subsystem: "com.siddharthrout.dB", category: "ProcessTap")

    let processObjectIDs: [AudioObjectID]

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.siddharthrout.dB.tap-io", qos: .userInteractive)
    private let gainState: OSAllocatedUnfairLock<Float>
    private var invalidated = false

    var gain: Float {
        get { gainState.withLock { $0 } }
        set { gainState.withLock { $0 = newValue } }
    }

    init(processObjectIDs: [AudioObjectID], name: String, initialGain: Float) throws {
        self.processObjectIDs = processObjectIDs
        self.gainState = OSAllocatedUnfairLock(initialState: initialGain)
        do {
            try activate(name: name)
        } catch {
            invalidate()
            throw error
        }
    }

    deinit {
        invalidate()
    }

    private func activate(name: String) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.name = "dB (\(name))"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            throw ProcessTapError.tapCreationFailed(status)
        }
        tapID = tap

        guard let outputDevice = CoreAudioUtils.defaultOutputDevice(),
              let outputUID = CoreAudioUtils.deviceUID(outputDevice) else {
            throw ProcessTapError.noOutputDevice
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "dB (\(name))",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard status == noErr, aggregate != kAudioObjectUnknown else {
            throw ProcessTapError.aggregateCreationFailed(status)
        }
        aggregateID = aggregate

        let state = gainState
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { _, inputData, _, outputData, _ in
            ProcessTap.render(input: inputData, output: outputData, gain: state.withLock { $0 })
        }
        guard status == noErr, let ioProcID else {
            throw ProcessTapError.ioProcCreationFailed(status)
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            throw ProcessTapError.deviceStartFailed(status)
        }

        Self.logger.info("Tap active for \(name, privacy: .public) (\(self.processObjectIDs.count) process(es))")
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true

        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Copies tapped input to the output device buffers, applying gain.
    /// Assumes Float32 samples on both sides (the HAL canonical format).
    private static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        gain: Float
    ) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        // Flatten input into per-channel views: (base pointer, stride, frame count).
        var inChannels: [(base: UnsafeMutablePointer<Float32>, stride: Int, frames: Int)] = []
        inChannels.reserveCapacity(2)
        for buffer in inList {
            guard let data = buffer.mData else { continue }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * channels)
            let base = data.assumingMemoryBound(to: Float32.self)
            for channel in 0..<channels {
                inChannels.append((base + channel, channels, frames))
            }
        }

        var outChannelIndex = 0
        for buffer in outList {
            guard let data = buffer.mData else { continue }
            if inChannels.isEmpty {
                memset(data, 0, Int(buffer.mDataByteSize))
                continue
            }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * channels)
            let base = data.assumingMemoryBound(to: Float32.self)
            for channel in 0..<channels {
                let source = inChannels[outChannelIndex % inChannels.count]
                let count = min(frames, source.frames)
                for frame in 0..<count {
                    base[frame * channels + channel] = source.base[frame * source.stride] * gain
                }
                if count < frames {
                    for frame in count..<frames {
                        base[frame * channels + channel] = 0
                    }
                }
                outChannelIndex += 1
            }
        }
    }
}
