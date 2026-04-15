//
//  LiveKitCameraService.swift
//  app_camera_p2p_v1
//

import LiveKit
import AVFoundation
import Combine
import SwiftUI
import UIKit

@MainActor
class LiveKitCameraService: NSObject, ObservableObject {

    @Published var room: Room?
    @Published var isConnected = false
    @Published var isPublishing = false
    @Published var errorMessage: String?

    private weak var localParticipant: LocalParticipant?
    @Published private(set) var cameraTrack: LocalVideoTrack?
    private var videoPublication: LocalTrackPublication?

    let serverURL: String
    let token: String
    let roomName: String

    // MARK: - Photo Capture Properties
    private let photoOutput = AVCapturePhotoOutput()
    private var captureContinuation: CheckedContinuation<Void, Never>?

    // MARK: - Camera State
    @Published var zoomFactor: CGFloat = 1.0
    var maxZoomFactor: CGFloat = 8.0

    // Tracks whether a camera position switch is in progress.
    // Used to prevent simultaneous capture during switch.
    @Published private(set) var isSwitchingCamera = false

    init(serverURL: String, token: String, roomName: String) {
        self.serverURL = serverURL
        self.token = token
        self.roomName = roomName
        super.init()
    }

    // MARK: - Camera Controls

    func switchCamera() {
        guard let track = cameraTrack,
              let capturer = track.capturer as? CameraCapturer,
              !isSwitchingCamera else { return }

        isSwitchingCamera = true

        Task {
            do {
                try await capturer.switchCameraPosition()
                // Re-inject photoOutput after switching so it connects
                // to the new AVCaptureDeviceInput.
                self.setupPhotoOutput()
            } catch {
                self.errorMessage = "Không thể đổi camera: \(error.localizedDescription)"
            }
            self.isSwitchingCamera = false
        }
    }

    func setZoom(factor: CGFloat) {
        guard let track = cameraTrack,
              let capturer = track.capturer as? CameraCapturer,
              let device = capturer.device else { return }

        let clampedFactor = min(max(factor, 1.0), min(device.activeFormat.videoMaxZoomFactor, 8.0))

        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clampedFactor
            device.unlockForConfiguration()
            self.zoomFactor = clampedFactor
            self.maxZoomFactor = min(device.activeFormat.videoMaxZoomFactor, 8.0)
        } catch {
            print("Zoom error: \(error)")
        }
    }

    // MARK: - Connection & Publishing

    func connect() async {
        do {
            let newRoom = Room(delegate: self)
            let connectOptions = ConnectOptions(autoSubscribe: false)
            let roomOptions = RoomOptions(
                defaultCameraCaptureOptions: CameraCaptureOptions(
                    position: .front,
                    dimensions: .h1440_43,
                    fps: 24
                )
            )

            try await newRoom.connect(
                url: serverURL,
                token: token,
                connectOptions: connectOptions,
                roomOptions: roomOptions
            )

            self.room = newRoom
            self.localParticipant = newRoom.localParticipant
            self.isConnected = true
            print("✅ Connected to room: \(roomName)")

        } catch {
            errorMessage = "Connect failed: \(error.localizedDescription)"
        }
    }

    func startPublishingCamera() async {
        guard let room = room, cameraTrack == nil else { return }

        do {
            try await room.localParticipant.setCamera(enabled: true)

            // FIX: Thay delay cứng 300ms bằng vòng lặp polling có timeout.
            // Chờ cho đến khi track thực sự sẵn sàng, tối đa 2 giây.
            let deadline = Date().addingTimeInterval(2.0)
            while Date() < deadline {
                if let track = room.localParticipant.firstCameraVideoTrack as? LocalVideoTrack {
                    self.cameraTrack = track
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000) // poll mỗi 50ms
            }

            guard cameraTrack != nil else {
                errorMessage = "Camera track không khởi động được sau 2 giây."
                return
            }

            setupPhotoOutput()
            self.isPublishing = true

        } catch {
            errorMessage = "Publish camera failed: \(error)"
        }
    }

    func stopPublishing() async {
        guard let room = room else { return }
        do {
            if let publication = videoPublication {
                try await room.localParticipant.unpublish(publication: publication)
                videoPublication = nil
            } else {
                try await room.localParticipant.setCamera(enabled: false)
            }
        } catch {
            print("⚠️ Unpublish error: \(error)")
        }
        cameraTrack = nil
        isPublishing = false
    }

    func disconnect() async {
        await stopPublishing()
        await room?.disconnect()
        isConnected = false
        room = nil
    }

    // MARK: - Photo Output Setup

    /// Inject AVCapturePhotoOutput vào AVCaptureSession của LiveKit.
    /// Phải gọi lại mỗi khi switch camera vì DeviceInput thay đổi.
    private func setupPhotoOutput() {
        guard let track = cameraTrack,
              let capturer = track.capturer as? CameraCapturer else { return }

        let session = capturer.captureSession

        session.beginConfiguration()

        if session.outputs.contains(photoOutput) {
            session.removeOutput(photoOutput)
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)

            // FIX: isHighResolutionCaptureEnabled deprecated từ iOS 16.
            // Trên iOS 16+ hệ thống tự dùng full resolution, không cần set.
            if #unavailable(iOS 16.0) {
                photoOutput.isHighResolutionCaptureEnabled = true
            }

            if #available(iOS 13.0, *) {
                photoOutput.maxPhotoQualityPrioritization = .quality
            }

            print("✅ Đã inject AVCapturePhotoOutput vào LiveKit session")
        }

        session.commitConfiguration()
    }

    // MARK: - Capture

    func captureAndSavePhoto() async {
        guard photoOutput.connections.count > 0 else {
            self.errorMessage = "Camera chưa sẵn sàng để chụp ảnh."
            return
        }

        print("📸 Đang yêu cầu cảm biến chụp ảnh...")

        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = self.photoOutput.maxPhotoQualityPrioritization

        // FIX: isHighResolutionPhotoEnabled deprecated từ iOS 16.
        if #unavailable(iOS 16.0) {
            if photoOutput.isHighResolutionCaptureEnabled {
                settings.isHighResolutionPhotoEnabled = true
            }
        }

        await withCheckedContinuation { continuation in
            self.captureContinuation = continuation
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension LiveKitCameraService: AVCapturePhotoCaptureDelegate {

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        Task { @MainActor in
            // defer đảm bảo continuation luôn được resume dù xảy ra lỗi gì,
            // tránh deadlock cho captureAndSavePhoto().
            defer {
                self.captureContinuation?.resume()
                self.captureContinuation = nil
            }

            if let error = error {
                self.errorMessage = "Lỗi phần cứng chụp ảnh: \(error.localizedDescription)"
                return
            }

            guard let fileData = photo.fileDataRepresentation(),
                  let image = UIImage(data: fileData) else {
                self.errorMessage = "Lỗi xử lý file ảnh."
                return
            }

            // FIX: Thêm selector callback để xử lý lỗi lưu ảnh (ví dụ: thiếu quyền).
            // Nếu dùng nil,nil,nil thì lỗi sẽ bị nuốt im lặng.
            UIImageWriteToSavedPhotosAlbum(
                image,
                self,
                #selector(handleSaveResult(_:didFinishSavingWithError:contextInfo:)),
                nil
            )
        }
    }

    /// Callback sau khi UIImageWriteToSavedPhotosAlbum hoàn thành.
    /// Phải là @objc vì được gọi qua Objective-C runtime.
    @objc nonisolated private func handleSaveResult(
        _ image: UIImage,
        didFinishSavingWithError error: Error?,
        contextInfo: UnsafeRawPointer
    ) {
        Task { @MainActor in
            if let error = error {
                // Thường gặp: NSPhotoLibraryAddUsageDescription chưa được khai báo
                // hoặc user từ chối quyền truy cập thư viện ảnh.
                self.errorMessage = "Không thể lưu ảnh: \(error.localizedDescription)"
                print("❌ Lưu ảnh thất bại: \(error)")
            } else {
                print("✅ Đã lưu ảnh vào thư viện thành công!")
            }
        }
    }
}

// MARK: - RoomDelegate

extension LiveKitCameraService: RoomDelegate {

    nonisolated func room(
        _ room: Room,
        didUpdateConnectionState state: ConnectionState,
        from oldState: ConnectionState
    ) {
        if state == .disconnected {
            Task { @MainActor in self.isConnected = false }
        }
    }

    nonisolated func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        let msg = error?.localizedDescription ?? "Unknown error"
        Task { @MainActor in self.errorMessage = "Failed to connect: \(msg)" }
    }

    nonisolated func room(_ room: Room,
                          participant: RemoteParticipant?,
                          didReceiveData data: Data,
                          forTopic topic: String,
                          encryptionType: EncryptionType) {
        guard topic == "camera_control",
              let command = String(data: data, encoding: .utf8) else { return }
        print("📨 Nhận lệnh từ viewer: \(command)")
        if command == "switch_camera" {
            Task { @MainActor in self.switchCamera() }
        }
    }
}
