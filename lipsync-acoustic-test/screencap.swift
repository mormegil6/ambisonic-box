// Records the main display and the system audio with ScreenCaptureKit, both timestamped on the host clock, so that the
// picture and the sound can be compared without asking the browser when it painted a frame.
// usage: screencap <seconds> <out-prefix>      writes <out-prefix>.luma.tsv (host time in s, mean luma 0..1, one line per
//        captured frame) and <out-prefix>.audio.f32 (mono float32, 48 kHz) with <out-prefix>.audio.json (host time of the
//        first sample). Needs Screen Recording permission for the process that runs it.
import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

final class Rec: NSObject, SCStreamOutput, SCStreamDelegate {
    let lumaOut: FileHandle, audioOut: FileHandle, prefix: String
    var firstAudioHost: Double? = nil
    var audioSamples = 0
    var frames = 0
    init(prefix: String) throws {
        self.prefix = prefix
        FileManager.default.createFile(atPath: prefix + ".luma.tsv", contents: nil)
        FileManager.default.createFile(atPath: prefix + ".audio.f32", contents: nil)
        lumaOut = try FileHandle(forWritingTo: URL(fileURLWithPath: prefix + ".luma.tsv"))
        audioOut = try FileHandle(forWritingTo: URL(fileURLWithPath: prefix + ".audio.f32"))
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))   // host clock (mach absolute time) in seconds
        if type == .screen {
            // Only frames whose status is .complete carry new content.
            if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
               let raw = att.first?[.status] as? Int, let st = SCFrameStatus(rawValue: raw), st != .complete { return }
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
            guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return }
            var s = 0, n = 0
            var y = 0
            while y < h { var x = 0; while x < w { let p = base + y * bpr + x * 4; s += Int(p[0]) + Int(p[1]) + Int(p[2]); n += 1; x += 8 }; y += 8 }
            frames += 1
            lumaOut.write(String(format: "%.6f\t%.4f\n", t, Double(s) / Double(n * 3 * 255)).data(using: .utf8)!)
        } else if type == .audio {
            guard let fmt = CMSampleBufferGetFormatDescription(sb), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return }
            var block: CMBlockBuffer?
            var size = 0
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
            let ablPtr = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16).assumingMemoryBound(to: AudioBufferList.self)
            defer { ablPtr.deallocate() }
            guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: ablPtr, bufferListSize: size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr else { return }
            let list = UnsafeMutableAudioBufferListPointer(ablPtr)
            let nFrames = CMSampleBufferGetNumSamples(sb)
            if firstAudioHost == nil { firstAudioHost = t; FileHandle.standardError.write("audio: \(asbd.mSampleRate) Hz, \(list.count) buffers, \(asbd.mChannelsPerFrame) ch\n".data(using: .utf8)!) }
            // Non-interleaved float32: take the first channel. Pad with silence if a buffer arrives later than expected.
            let expect = Int(((t - firstAudioHost!) * asbd.mSampleRate).rounded())
            if expect > audioSamples + 48 { audioOut.write(Data(count: (expect - audioSamples) * 4)); audioSamples = expect }
            if let d = list[0].mData { audioOut.write(Data(bytes: d, count: nFrames * 4)); audioSamples += nFrames }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { FileHandle.standardError.write("stopped: \(error)\n".data(using: .utf8)!); exit(2) }
    func finish() {
        try? lumaOut.close(); try? audioOut.close()
        let j = "{\"firstAudioHost\": \(firstAudioHost ?? -1), \"sampleRate\": 48000, \"samples\": \(audioSamples), \"frames\": \(frames)}\n"
        FileManager.default.createFile(atPath: prefix + ".audio.json", contents: j.data(using: .utf8))
    }
}

let args = CommandLine.arguments
guard args.count == 3, let secs = Double(args[1]) else { print("usage: screencap <seconds> <out-prefix>"); exit(1) }
let rec = try Rec(prefix: args[2])
let sem = DispatchSemaphore(value: 0)
var stream: SCStream?
SCShareableContent.getWithCompletionHandler { content, err in
    guard let content = content, let display = content.displays.first else { print("no display (Screen Recording permission?): \(String(describing: err))"); exit(3) }
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let cfg = SCStreamConfiguration()
    cfg.width = display.width / 2; cfg.height = display.height / 2
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 120)
    cfg.queueDepth = 8
    cfg.showsCursor = false
    cfg.capturesAudio = true; cfg.sampleRate = 48000; cfg.channelCount = 1
    cfg.excludesCurrentProcessAudio = true
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
    let s = SCStream(filter: filter, configuration: cfg, delegate: rec)
    do {
        try s.addStreamOutput(rec, type: .screen, sampleHandlerQueue: DispatchQueue(label: "v"))
        try s.addStreamOutput(rec, type: .audio, sampleHandlerQueue: DispatchQueue(label: "a"))
    } catch { print("addStreamOutput: \(error)"); exit(4) }
    s.startCapture { e in if let e = e { print("start: \(e)"); exit(5) }; sem.signal() }
    stream = s
}
sem.wait()
FileHandle.standardError.write("recording \(secs) s\n".data(using: .utf8)!)
Thread.sleep(forTimeInterval: secs)
let done = DispatchSemaphore(value: 0)
stream?.stopCapture { _ in done.signal() }
_ = done.wait(timeout: .now() + 5)
rec.finish()
FileHandle.standardError.write("done: \(rec.frames) frames, \(rec.audioSamples) samples\n".data(using: .utf8)!)
