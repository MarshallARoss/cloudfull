//
//  LivePhotoGen.swift
//  Cloudfull
//
//  Copyright (C) 2026 Marshall Ross.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

// LivePhotoGen remuxes an ffmpeg-produced H.264+AAC `raw.mov` file into a
// PhotoKit Live Photo pair. It writes a still JPEG that carries the
// Apple maker-note content identifier
// (kCGImagePropertyMakerAppleDictionary["17"]). It writes a paired
// `motion.mov` file that carries the same identifier as movie-level
// metadata (com.apple.quicktime.content.identifier), plus a timed metadata
// track (com.apple.quicktime.still-image-time, data type
// kCMMetadataBaseDataType_SInt8).
//
// PhotoKit's importer treats a still and video pair as one Live Photo
// (ZKINDSUBTYPE=2, ZPLAYBACKSTYLE=3) only when both sides carry a matching
// content identifier and the video carries the still-image-time track. A
// pair with matching identifiers but no still-image-time track imports as
// two separate, unpaired assets.
//
// This file is not part of any Xcode target. The app does not build it.
// `scripts/seed_photos.sh` compiles it on demand
// (`xcrun -sdk macosx swiftc -O`) into `build/` and runs it once per
// invocation to produce the Live Photo fixture the simulator library needs.
//
// When `xcrun simctl addmedia` imports the still and video pair, Photos.sqlite
// gets one ZASSET row with ZKINDSUBTYPE=2 and ZPLAYBACKSTYLE=3, and two
// ZINTERNALRESOURCE rows: ZRESOURCETYPE=0 for the still, ZRESOURCETYPE=3 for
// the paired video.
//
// Usage: LivePhotoGen <uuid> <stillOutPath.jpg> <rawMovInPath> <motionOutPath.mov>

import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics
import ImageIO
import CoreServices

guard CommandLine.arguments.count == 5 else {
    FileHandle.standardError.write("Usage: LivePhotoGen <uuid> <stillOut.jpg> <rawMovIn> <motionOut.mov>\n".data(using: .utf8)!)
    exit(1)
}

let uuidString = CommandLine.arguments[1]
let stillOutPath = CommandLine.arguments[2]
let rawMovInPath = CommandLine.arguments[3]
let motionOutPath = CommandLine.arguments[4]

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("FAIL: \(msg)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Step 1: build the still image with its content identifier

func makeStillImage(uuid: String, outPath: String) {
    let width = 1200
    let height = 1600
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        fail("could not create CGContext")
    }
    // Fill the image with solid blue. This color is easy to identify in tests.
    ctx.setFillColor(red: 0.0, green: 0.0, blue: 1.0, alpha: 1.0)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    guard let cgImage = ctx.makeImage() else {
        fail("could not make CGImage")
    }

    let outURL = URL(fileURLWithPath: outPath)
    guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.jpeg" as CFString, 1, nil) else {
        fail("could not create CGImageDestination")
    }

    let makerApple: [String: Any] = ["17": uuid]
    let properties: [CFString: Any] = [
        kCGImagePropertyMakerAppleDictionary: makerApple
    ]

    CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        fail("could not finalize still image")
    }
    print("Wrote still image to \(outPath)")
}

func verifyStillImage(path: String) {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        fail("could not read back still image")
    }
    guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
        fail("could not read back still image properties")
    }
    guard let maker = props[kCGImagePropertyMakerAppleDictionary] as? [String: Any] else {
        fail("MakerApple dictionary missing on readback! props keys: \(props.keys)")
    }
    print("Readback MakerApple dict: \(maker)")
    guard let readUUID = maker["17"] as? String, readUUID == uuidString else {
        fail("MakerApple[17] mismatch or missing: \(maker)")
    }
    print("VERIFIED still.jpg contains matching content identifier: \(readUUID)")
}

// MARK: - Step 2: remux raw.mov into motion.mov with the content identifier and still-image-time track

func remux(uuid: String, rawURL: URL, outURL: URL) {
    if FileManager.default.fileExists(atPath: outURL.path) {
        try? FileManager.default.removeItem(at: outURL)
    }

    let asset = AVURLAsset(url: rawURL)

    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
        fail("raw.mov has no video track")
    }
    let audioTrack = asset.tracks(withMediaType: .audio).first
    if audioTrack == nil {
        print("WARNING: raw.mov has no audio track")
    }

    guard let reader = try? AVAssetReader(asset: asset) else {
        fail("could not create AVAssetReader")
    }

    let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
    videoOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(videoOutput) else { fail("cannot add video reader output") }
    reader.add(videoOutput)

    var audioOutput: AVAssetReaderTrackOutput?
    if let audioTrack = audioTrack {
        let ao = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        ao.alwaysCopiesSampleData = false
        guard reader.canAdd(ao) else { fail("cannot add audio reader output") }
        reader.add(ao)
        audioOutput = ao
    }

    guard let writer = try? AVAssetWriter(outputURL: outURL, fileType: .mov) else {
        fail("could not create AVAssetWriter")
    }

    guard let videoFormatDesc = videoTrack.formatDescriptions.first else {
        fail("video track has no format description")
    }
    // swiftlint:disable:next force_cast
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: (videoFormatDesc as! CMFormatDescription))
    videoInput.expectsMediaDataInRealTime = false
    guard writer.canAdd(videoInput) else { fail("cannot add video writer input") }
    writer.add(videoInput)

    var audioInput: AVAssetWriterInput?
    if let audioTrack = audioTrack, let audioFormatDesc = audioTrack.formatDescriptions.first {
        let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: (audioFormatDesc as! CMFormatDescription))
        ai.expectsMediaDataInRealTime = false
        guard writer.canAdd(ai) else { fail("cannot add audio writer input") }
        writer.add(ai)
        audioInput = ai
    }

    // Create the timed metadata track that PhotoKit needs to pair the still and the video.
    let keySpace = AVMetadataKeySpace.quickTimeMetadata.rawValue
    let stillImageTimeKey = "com.apple.quicktime.still-image-time"
    let spec: [String: Any] = [
        kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
            "\(keySpace)/\(stillImageTimeKey)",
        kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
            kCMMetadataBaseDataType_SInt8
    ]
    var metadataFormatDescOpt: CMFormatDescription?
    let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
        allocator: kCFAllocatorDefault,
        metadataType: kCMMetadataFormatType_Boxed,
        metadataSpecifications: [spec] as CFArray,
        formatDescriptionOut: &metadataFormatDescOpt
    )
    guard status == noErr, let metadataFormatDesc = metadataFormatDescOpt else {
        fail("could not create metadata format description, status=\(status)")
    }

    let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: metadataFormatDesc)
    metadataInput.expectsMediaDataInRealTime = false
    guard writer.canAdd(metadataInput) else { fail("cannot add metadata writer input") }
    writer.add(metadataInput)
    let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)

    // Write the content identifier as movie-level metadata. It must match MakerApple["17"] in the still.
    let identifierItem = AVMutableMetadataItem()
    identifierItem.identifier = AVMetadataIdentifier("mdta/com.apple.quicktime.content.identifier")
    identifierItem.keySpace = .quickTimeMetadata
    identifierItem.key = "com.apple.quicktime.content.identifier" as NSString
    identifierItem.value = uuid as NSString
    identifierItem.dataType = "com.apple.metadata.datatype.UTF-8"
    writer.metadata = [identifierItem]

    guard writer.startWriting() else {
        fail("writer.startWriting() failed: \(String(describing: writer.error))")
    }
    reader.startReading()
    writer.startSession(atSourceTime: .zero)

    // Add the still-image-time metadata sample near the start of the clip.
    let stillItem = AVMutableMetadataItem()
    stillItem.keySpace = .quickTimeMetadata
    stillItem.key = stillImageTimeKey as NSString
    stillItem.value = NSNumber(value: Int8(-1))
    stillItem.dataType = kCMMetadataBaseDataType_SInt8 as String
    let timeRange = CMTimeRange(start: CMTime(value: 0, timescale: 600), duration: CMTime(value: 20, timescale: 600))
    let group = AVTimedMetadataGroup(items: [stillItem], timeRange: timeRange)
    if !metadataAdaptor.append(group) {
        print("WARNING: metadataAdaptor.append(group) returned false: \(String(describing: writer.error))")
    }
    metadataInput.markAsFinished()

    let videoQueue = DispatchQueue(label: "video.remux")
    let videoSem = DispatchSemaphore(value: 0)
    videoInput.requestMediaDataWhenReady(on: videoQueue) {
        while videoInput.isReadyForMoreMediaData {
            if let sample = videoOutput.copyNextSampleBuffer() {
                if !videoInput.append(sample) {
                    print("WARNING: video append failed: \(String(describing: writer.error))")
                    videoInput.markAsFinished()
                    videoSem.signal()
                    return
                }
            } else {
                videoInput.markAsFinished()
                videoSem.signal()
                return
            }
        }
    }
    videoSem.wait()

    if let audioInput = audioInput, let audioOutput = audioOutput {
        let audioQueue = DispatchQueue(label: "audio.remux")
        let audioSem = DispatchSemaphore(value: 0)
        audioInput.requestMediaDataWhenReady(on: audioQueue) {
            while audioInput.isReadyForMoreMediaData {
                if let sample = audioOutput.copyNextSampleBuffer() {
                    if !audioInput.append(sample) {
                        print("WARNING: audio append failed: \(String(describing: writer.error))")
                        audioInput.markAsFinished()
                        audioSem.signal()
                        return
                    }
                } else {
                    audioInput.markAsFinished()
                    audioSem.signal()
                    return
                }
            }
        }
        audioSem.wait()
    }

    let finishSem = DispatchSemaphore(value: 0)
    writer.finishWriting {
        finishSem.signal()
    }
    finishSem.wait()

    if writer.status != .completed {
        fail("writer did not complete: status=\(writer.status.rawValue) error=\(String(describing: writer.error))")
    }
    print("Wrote motion.mov to \(outURL.path)")
}

func verifyMotionMov(path: String, uuid: String) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let commonMeta = asset.metadata
    var found = false
    for item in commonMeta {
        if let key = item.key as? String, key == "com.apple.quicktime.content.identifier" {
            let val = item.value as? String
            print("Readback movie content identifier: \(val ?? "nil")")
            if val == uuid { found = true }
        }
        if let identifier = item.identifier?.rawValue, identifier.contains("content.identifier") {
            let val = item.value as? String
            print("Readback (by identifier) movie content identifier: \(val ?? "nil")")
            if val == uuid { found = true }
        }
    }
    if !found {
        fail("motion.mov content identifier missing or mismatched")
    }
    print("VERIFIED motion.mov contains matching content identifier: \(uuid)")

    let metaTracks = asset.tracks(withMediaType: .metadata)
    print("metadata tracks count: \(metaTracks.count)")
    if metaTracks.isEmpty {
        fail("motion.mov has no metadata track (still-image-time track missing)")
    }
    let videoTracks = asset.tracks(withMediaType: .video)
    let audioTracks = asset.tracks(withMediaType: .audio)
    print("video tracks: \(videoTracks.count), audio tracks: \(audioTracks.count)")
    if audioTracks.isEmpty {
        fail("motion.mov has no audio track")
    }
}

print("=== Step 1: still image ===")
makeStillImage(uuid: uuidString, outPath: stillOutPath)
verifyStillImage(path: stillOutPath)

print("=== Step 2: motion.mov remux ===")
remux(uuid: uuidString, rawURL: URL(fileURLWithPath: rawMovInPath), outURL: URL(fileURLWithPath: motionOutPath))
verifyMotionMov(path: motionOutPath, uuid: uuidString)

print("=== DONE ===")
