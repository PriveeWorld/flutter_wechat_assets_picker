import Flutter
import AVFoundation
import Photos

public class VideoProcessorPlugin: NSObject, FlutterPlugin {
    private let channelName = "wechat_assets_picker/video_processor"
    private var exporter: AVAssetExportSession?
    private var progressTimer: Timer?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "wechat_assets_picker/video_processor",
            binaryMessenger: registrar.messenger()
        )
        let instance = VideoProcessorPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "processVideo":
            guard let args = call.arguments as? [String: Any],
                  let inputPath = args["path"] as? String else {
                result(FlutterError(code: "INVALID_ARGS",
                                   message: "Missing path",
                                   details: nil))
                return
            }
            processVideo(inputPath: inputPath, result: result)

        case "getVideoCodec":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String else {
                result(FlutterError(code: "INVALID_ARGS",
                                   message: "Missing path",
                                   details: nil))
                return
            }
            result(getVideoCodec(path: path))

        case "getProgress":
            if let exporter = self.exporter {
                result(exporter.progress)
            } else {
                result(0.0)
            }

        case "cancelProcessing":
            if let exporter = self.exporter {
                exporter.cancelExport()
                self.exporter = nil
                result(true)
            } else {
                result(false)
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func processVideo(inputPath: String, result: @escaping FlutterResult) {
        let inputURL = URL(fileURLWithPath: inputPath)
        let asset = AVURLAsset(url: inputURL)

        // Check if conversion needed
        let codec = getVideoCodec(path: inputPath)
        print("[VideoProcessor] Input video codec: \(codec)")

        // For screen recordings and HEVC videos, force conversion
        let needsConversion = codec == "h265" || inputPath.lowercased().contains("screenrecording")

        if !needsConversion {
            print("[VideoProcessor] Video already compatible, returning original")
            result(inputPath)
            return
        }

        print("[VideoProcessor] Converting H.265/HEVC to H.264...")

        // Generate output path
        let tempDir = NSTemporaryDirectory()
        let fileName = "wechat_converted_\(UUID().uuidString).mp4"
        let outputURL = URL(fileURLWithPath: tempDir).appendingPathComponent(fileName)

        // Remove existing file if any
        try? FileManager.default.removeItem(at: outputURL)

        // Create export session with highest quality
        // This preset ensures compatibility while maintaining quality
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPreset1920x1080  // Force 1080p H.264
        ) else {
            // Fallback to highest quality if 1080p not available
            guard let fallbackExporter = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetHighestQuality
            ) else {
                result(FlutterError(code: "EXPORT_FAILED",
                                   message: "Failed to create export session",
                                   details: nil))
                return
            }
            self.exporter = fallbackExporter
            configureAndExport(exporter: fallbackExporter, outputURL: outputURL, result: result)
            return
        }

        self.exporter = exporter
        configureAndExport(exporter: exporter, outputURL: outputURL, result: result)
    }

    private func configureAndExport(exporter: AVAssetExportSession, outputURL: URL, result: @escaping FlutterResult) {
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4  // Forces H.264 codec
        exporter.shouldOptimizeForNetworkUse = true

        // Get the source asset for video composition
        guard let sourceAsset = exporter.asset else {
            result(FlutterError(code: "EXPORT_FAILED",
                               message: "Failed to get source asset",
                               details: nil))
            return
        }

        // Force video composition to ensure re-encoding
        // This is critical for H.265 to H.264 conversion
        let videoComposition = AVMutableVideoComposition(propertiesOf: sourceAsset)

        // Set frame rate to 30 FPS for consistency
        videoComposition.frameDuration = CMTimeMake(value: 1, timescale: 30)

        // Apply the video composition
        exporter.videoComposition = videoComposition

        // Track progress
        self.progressTimer?.invalidate()
        self.progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            print("[VideoProcessor] Progress: \(Int(exporter.progress * 100))%")
        }

        // Export asynchronously
        exporter.exportAsynchronously { [weak self] in
            self?.progressTimer?.invalidate()
            self?.progressTimer = nil

            switch exporter.status {
            case .completed:
                print("[VideoProcessor] Export completed successfully")

                // Verify the output file
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    do {
                        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
                        let fileSize = attributes[.size] as? Int64 ?? 0
                        print("[VideoProcessor] Output file size: \(fileSize / 1024 / 1024) MB")

                        // Verify codec of output
                        let outputCodec = self?.getVideoCodec(path: outputURL.path) ?? "unknown"
                        print("[VideoProcessor] Output codec: \(outputCodec)")

                        result(outputURL.path)
                    } catch {
                        result(FlutterError(code: "EXPORT_FAILED",
                                           message: "Failed to verify output file",
                                           details: error.localizedDescription))
                    }
                } else {
                    result(FlutterError(code: "EXPORT_FAILED",
                                       message: "Output file does not exist",
                                       details: nil))
                }

            case .failed:
                print("[VideoProcessor] Export failed: \(exporter.error?.localizedDescription ?? "Unknown error")")
                result(FlutterError(code: "EXPORT_FAILED",
                                   message: exporter.error?.localizedDescription ?? "Export failed",
                                   details: nil))

            case .cancelled:
                print("[VideoProcessor] Export cancelled")
                result(FlutterError(code: "EXPORT_CANCELLED",
                                   message: "Export was cancelled",
                                   details: nil))

            default:
                result(FlutterError(code: "EXPORT_UNKNOWN",
                                   message: "Unknown export status: \(exporter.status.rawValue)",
                                   details: nil))
            }

            self?.exporter = nil
        }
    }

    private func getVideoCodec(path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)

        guard let track = asset.tracks(withMediaType: .video).first else {
            return "unknown"
        }

        guard let formatDescriptions = track.formatDescriptions as? [CMFormatDescription],
              let formatDescription = formatDescriptions.first else {
            return "unknown"
        }

        let codec = CMFormatDescriptionGetMediaSubType(formatDescription)

        switch codec {
        case kCMVideoCodecType_H264:
            return "h264"
        case kCMVideoCodecType_HEVC:
            return "h265"
        case kCMVideoCodecType_MPEG4Video:
            return "mpeg4"
        case kCMVideoCodecType_JPEG:
            return "jpeg"
        default:
            // Convert FourCC to string for debugging
            let codecString = fourCCToString(codec)
            print("[VideoProcessor] Unknown codec: \(codecString)")
            return "other:\(codecString)"
        }
    }

    private func fourCCToString(_ fourCC: FourCharCode) -> String {
        let bytes = [
            UInt8((fourCC >> 24) & 0xFF),
            UInt8((fourCC >> 16) & 0xFF),
            UInt8((fourCC >> 8) & 0xFF),
            UInt8(fourCC & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}