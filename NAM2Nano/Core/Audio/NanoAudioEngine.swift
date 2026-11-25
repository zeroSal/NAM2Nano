import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import Observation

/// Level/health snapshot published to the UI (~30 Hz).
struct AudioMeters: Equatable {
    var sourceDB: Float = -120
    var modelInDB: Float = -120
    var outputDB: Float = -120
    var xruns: UInt32 = 0
    var clips: UInt32 = 0
    var dspOverloads: UInt32 = 0
    var deviceOverloads: UInt32 = 0
    var cpuLoad: Float = 0

    var totalDropouts: UInt32 { xruns + dspOverloads + deviceOverloads }

    static func db(_ linear: Float) -> Float { linear > 1e-6 ? 20 * log10(linear) : -120 }
}

enum NanoAudioEngineError: LocalizedError {
    case microphoneDenied
    case coreAudio(String, OSStatus)
    case noNanoDevice

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Audio input access denied. Enable NAM2Nano in System Settings → Privacy & Security → Microphone."
        case .coreAudio(let what, let status): return "CoreAudio: \(what) failed (\(status))."
        case .noNanoDevice: return "Nano Cortex USB device not found."
        }
    }
}

// MARK: - Real-time render context (plain memory, no ARC on the audio thread)

struct RenderContext {
    var unit: AudioUnit?
    var engine: UnsafeMutableRawPointer?
    var inputList: UnsafeMutablePointer<AudioBufferList>?
    var inputStorage: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?
    var inputPointers: UnsafeMutablePointer<UnsafePointer<Float>?>?
    var inputChannels: Int32 = 0
    var outputPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?
    var maxOutputChannels: Int32 = 0
    var maxFrames: UInt32 = 0
    var outputChannel: Int32 = 0
}

/// AUHAL output-bus render callback. Pulls the input bus (same device, same clock),
/// hands raw channel pointers to the C++ engine, which writes the processed signal
/// on the selected output channel. No allocation, no locks, no Swift objects.
private let nanoRenderCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, ioData in
    let ctx = inRefCon.assumingMemoryBound(to: RenderContext.self)
    guard let ioData else { return noErr }
    let outList = UnsafeMutableAudioBufferListPointer(ioData)

    guard let engine = ctx.pointee.engine, let unit = ctx.pointee.unit,
          let outPtrs = ctx.pointee.outputPointers, inNumberFrames <= ctx.pointee.maxFrames else {
        for buffer in outList { if let d = buffer.mData { memset(d, 0, Int(buffer.mDataByteSize)) } }
        return noErr
    }

    var inCount: Int32 = 0
    if let inList = ctx.pointee.inputList, let storage = ctx.pointee.inputStorage,
       let inPtrs = ctx.pointee.inputPointers, ctx.pointee.inputChannels > 0 {
        var abl = UnsafeMutableAudioBufferListPointer(inList)
        for i in 0..<abl.count {
            abl[i].mData = UnsafeMutableRawPointer(storage[i])
            abl[i].mDataByteSize = inNumberFrames * UInt32(MemoryLayout<Float>.size)
        }
        let status = AudioUnitRender(unit, ioActionFlags, inTimeStamp, 1, inNumberFrames, inList)
        if status == noErr {
            inCount = ctx.pointee.inputChannels
            for i in 0..<Int(inCount) {
                inPtrs[i] = UnsafePointer(abl[i].mData?.assumingMemoryBound(to: Float.self))
            }
        } else {
            NAMEngineReportHostError(engine)
        }
    }

    let outCount = min(Int32(outList.count), ctx.pointee.maxOutputChannels)
    for i in 0..<Int(outCount) {
        outPtrs[i] = outList[i].mData?.assumingMemoryBound(to: Float.self)
    }
    NAMEngineRender(engine,
                    inCount > 0 ? UnsafePointer(ctx.pointee.inputPointers) : nil, inCount,
                    UnsafePointer(outPtrs), outCount,
                    ctx.pointee.outputChannel, Int32(inNumberFrames))
    return noErr
}

/// Wrapper so the (thread-safe) bridge can be used from a detached loading task.
private final class ProcessorBox: @unchecked Sendable {
    let bridge: NAMProcessorBridge
    init(_ bridge: NAMProcessorBridge) { self.bridge = bridge }
}

private final class LoadResultBox: @unchecked Sendable {
    let result: NAMModelLoadResult
    init(_ result: NAMModelLoadResult) { self.result = result }
}

/// CoreAudio engine bound to the Nano Cortex USB device.
///
/// One AUHAL instance runs full duplex on the Nano (input + output share the device
/// clock, so no drift compensation is needed). Fixed 48 kHz Float32 non-interleaved.
/// Routing: the capture test signal arrives on a USB input channel (default 4 = processed
/// OUTPUT 2R / CAPTURE OUT) and the NAM-processed result leaves on a USB output channel
/// (default 1 = OUTPUT 1L), from where the patch cable feeds CAPTURE IN.
@MainActor
@Observable
final class NanoAudioEngine {

    enum RunState: Equatable {
        case stopped
        case running(device: String, bufferFrames: UInt32)
        case failed(String)

        var isRunning: Bool { if case .running = self { return true } else { return false } }
    }

    static let sampleRate: Double = 48_000
    static let maxBlock = 4096

    private(set) var runState: RunState = .stopped
    private(set) var meters = AudioMeters()
    /// Peak (dBFS) of every USB input channel since the last poll.
    private(set) var inputChannelDB: [Float] = []
    private(set) var loadedModel: NAMModelLoadResult?
    private(set) var loadedModelURL: URL?
    private(set) var device: AudioDeviceInfo?

    let processor = NAMProcessorBridge(hostSampleRate: NanoAudioEngine.sampleRate, maxBlockSize: NanoAudioEngine.maxBlock)

    @ObservationIgnored private var unit: AudioUnit?
    @ObservationIgnored private let context: UnsafeMutablePointer<RenderContext>
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var deviceOverloads: UInt32 = 0
    @ObservationIgnored private var overloadListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var overloadDevice: AudioDeviceID?
    @ObservationIgnored private var inputABL: UnsafeMutableAudioBufferListPointer?

    init() {
        context = UnsafeMutablePointer<RenderContext>.allocate(capacity: 1)
        context.initialize(to: RenderContext())
        context.pointee.engine = processor.engineHandle
    }

    // MARK: Routing / parameters

    /// 0-based USB channels.
    func setRouting(sourceChannel: Int, outputChannel: Int) {
        processor.sourceChannel = sourceChannel
        context.pointee.outputChannel = Int32(outputChannel)
    }

    var outputChannel: Int { Int(context.pointee.outputChannel) }

    // MARK: Lifecycle

    func start(device: AudioDeviceInfo, bufferFrames: UInt32) async throws {
        if case .running = runState, self.device?.id == device.id { return }
        stop()

        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            runState = .failed(NanoAudioEngineError.microphoneDenied.localizedDescription)
            throw NanoAudioEngineError.microphoneDenied
        }

        do {
            try configureAndStart(device: device, bufferFrames: bufferFrames)
            self.device = device
            runState = .running(device: device.name, bufferFrames: bufferFrames)
            startMetering()
            watchOverloads(device.id)
        } catch {
            teardownUnit()
            runState = .failed(error.localizedDescription)
            throw error
        }
    }

    func stop() {
        meterTimer?.invalidate()
        meterTimer = nil
        unwatchOverloads()
        teardownUnit()
        device = nil
        if case .running = runState { runState = .stopped }
    }

    // MARK: Model

    func loadModel(at url: URL) async throws -> NAMModelLoadResult {
        let box = ProcessorBox(processor)
        let path = url.path
        let loaded = try await Task.detached(priority: .userInitiated) { () throws -> LoadResultBox in
            LoadResultBox(try box.bridge.loadModel(atPath: path))
        }.value
        loadedModel = loaded.result
        loadedModelURL = url
        return loaded.result
    }

    func unloadModel() {
        processor.unloadModel()
        loadedModel = nil
        loadedModelURL = nil
    }

    /// Convenience: silence everything going to the Nano.
    func goSilent() {
        processor.outputMuted = true
        processor.sourceMode = .silence
        processor.processThroughModel = false
    }

    // MARK: - AUHAL

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw NanoAudioEngineError.coreAudio(what, status) }
    }

    private static func floatFormat(channels: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }

    private func configureAndStart(device: AudioDeviceInfo, bufferFrames: UInt32) throws {
        if !device.isAt48k { AudioDeviceMonitor.setNominalSampleRate(device.id, Self.sampleRate) }
        AudioDeviceMonitor.setBufferFrameSize(device.id, bufferFrames)

        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw NanoAudioEngineError.coreAudio("AudioComponentFindNext(HALOutput)", -1)
        }
        var newUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &newUnit), "AudioComponentInstanceNew")
        guard let unit = newUnit else { throw NanoAudioEngineError.coreAudio("AudioComponentInstanceNew", -1) }
        self.unit = unit

        let u32 = UInt32(MemoryLayout<UInt32>.size)
        var one: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, u32),
                  "EnableIO input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, u32),
                  "EnableIO output")

        var deviceID = device.id
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)), "CurrentDevice")

        let inChannels = max(0, device.inputChannels)
        let outChannels = max(1, device.outputChannels)
        let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if inChannels > 0 {
            var inFormat = Self.floatFormat(channels: inChannels)
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                           &inFormat, asbdSize), "StreamFormat input bus")
        }
        var outFormat = Self.floatFormat(channels: outChannels)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                       &outFormat, asbdSize), "StreamFormat output bus")

        var maxFrames = UInt32(Self.maxBlock)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                       &maxFrames, u32), "MaximumFramesPerSlice")

        allocateBuffers(inputChannels: inChannels, outputChannels: outChannels, maxFrames: maxFrames)
        context.pointee.unit = unit

        var callback = AURenderCallbackStruct(inputProc: nanoRenderCallback,
                                              inputProcRefCon: UnsafeMutableRawPointer(context))
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                       &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "SetRenderCallback")

        try check(AudioUnitInitialize(unit), "AudioUnitInitialize")
        try check(AudioOutputUnitStart(unit), "AudioOutputUnitStart")
    }

    private func allocateBuffers(inputChannels: Int, outputChannels: Int, maxFrames: UInt32) {
        freeBuffers()
        let frames = Int(maxFrames)
        if inputChannels > 0 {
            var abl = AudioBufferList.allocate(maximumBuffers: inputChannels)
            let storage = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: inputChannels)
            for i in 0..<inputChannels {
                let buf = UnsafeMutablePointer<Float>.allocate(capacity: frames)
                buf.initialize(repeating: 0, count: frames)
                storage[i] = buf
                abl[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: UnsafeMutableRawPointer(buf))
            }
            let ptrs = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: inputChannels)
            ptrs.initialize(repeating: nil, count: inputChannels)
            inputABL = abl
            context.pointee.inputList = abl.unsafeMutablePointer
            context.pointee.inputStorage = storage
            context.pointee.inputPointers = ptrs
            context.pointee.inputChannels = Int32(inputChannels)
        }
        let outPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: outputChannels)
        outPtrs.initialize(repeating: nil, count: outputChannels)
        context.pointee.outputPointers = outPtrs
        context.pointee.maxOutputChannels = Int32(outputChannels)
        context.pointee.maxFrames = maxFrames
        inputChannelDB = Array(repeating: -120, count: inputChannels)
    }

    private func freeBuffers() {
        let n = Int(context.pointee.inputChannels)
        if let storage = context.pointee.inputStorage {
            for i in 0..<n { storage[i]?.deallocate() }
            storage.deallocate()
        }
        context.pointee.inputPointers?.deallocate()
        context.pointee.outputPointers?.deallocate()
        if let abl = inputABL { free(abl.unsafeMutablePointer) } // allocated with malloc by AudioBufferList.allocate
        inputABL = nil
        let engine = context.pointee.engine
        let outputChannel = context.pointee.outputChannel // keep the user's routing across restarts
        context.pointee = RenderContext()
        context.pointee.engine = engine
        context.pointee.outputChannel = outputChannel
    }

    private func teardownUnit() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        freeBuffers()
    }

    // MARK: Metering

    private func startMetering() {
        meterTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMeters() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func pollMeters() {
        let s = processor.readMetersResettingPeaks(true)
        var m = AudioMeters()
        m.sourceDB = AudioMeters.db(s.sourcePeak)
        m.modelInDB = AudioMeters.db(s.modelInPeak)
        m.outputDB = AudioMeters.db(s.outputPeak)
        m.xruns = s.xruns
        m.dspOverloads = s.overloads
        m.clips = s.clips
        m.cpuLoad = s.cpuLoad
        m.deviceOverloads = deviceOverloads
        meters = m
        inputChannelDB = (0..<inputChannelDB.count).map { AudioMeters.db(processor.inputChannelPeak($0, reset: true)) }
        processor.collectGarbage()
    }

    /// CoreAudio reports HAL-level overloads (missed IO cycles) on the device.
    private func watchOverloads(_ id: AudioDeviceID) {
        var address = AudioDeviceMonitor.address(kAudioDeviceProcessorOverload)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.deviceOverloads &+= 1 }
        }
        overloadListener = block
        overloadDevice = id
        AudioObjectAddPropertyListenerBlock(id, &address, DispatchQueue.main, block)
    }

    private func unwatchOverloads() {
        guard let id = overloadDevice, let block = overloadListener else { return }
        var address = AudioDeviceMonitor.address(kAudioDeviceProcessorOverload)
        AudioObjectRemovePropertyListenerBlock(id, &address, DispatchQueue.main, block)
        overloadDevice = nil
        overloadListener = nil
    }
}
