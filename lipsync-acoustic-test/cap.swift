// Sample-accurate capture of one CoreAudio input device to a float32 WAV until "q" arrives on stdin.
// usage: cap "<device name>" out.wav      (prints "started <epoch ms of the first buffer's host time>" on stdout)
import AVFoundation
import CoreAudio

func deviceID(named name: String) -> AudioDeviceID? {
    var size: UInt32 = 0
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    for id in ids {
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &sz, &cf) == noErr, let s = cf?.takeRetainedValue() as String?, s == name { return id }
    }
    return nil
}
let args = CommandLine.arguments
guard args.count == 3, let dev = deviceID(named: args[1]) else { FileHandle.standardError.write("device not found\n".data(using: .utf8)!); exit(2) }
let engine = AVAudioEngine()
let input = engine.inputNode
do { try input.auAudioUnit.setDeviceID(dev) } catch { FileHandle.standardError.write("setDeviceID failed: \(error)\n".data(using: .utf8)!); exit(3) }
let fmt = input.outputFormat(forBus: 0)
let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: fmt.sampleRate, AVNumberOfChannelsKey: fmt.channelCount,
                               AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
let file = try AVAudioFile(forWriting: URL(fileURLWithPath: args[2]), settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
var first = true
var frames: Int64 = 0
input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, when in
    if first {
        first = false
        let hostSec = AVAudioTime.seconds(forHostTime: when.hostTime)
        let nowSec = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let epochNow = Date().timeIntervalSince1970
        print("started epoch_ms_of_first_sample \(Int((epochNow - (nowSec - hostSec)) * 1000)) rate \(fmt.sampleRate) channels \(fmt.channelCount)")
        fflush(stdout)
    }
    try? file.write(from: buf)
    frames += Int64(buf.frameLength)
}
try engine.start()
DispatchQueue.global().async {
    while let l = readLine() { if l.hasPrefix("q") { break } }
    engine.stop(); input.removeTap(onBus: 0)
    print("frames \(frames)"); fflush(stdout)
    exit(0)
}
RunLoop.main.run()
