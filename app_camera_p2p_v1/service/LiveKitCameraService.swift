//
//  LiveKitCameraService.swift
//  app_camera_p2p_v1
//

import LiveKit
import AVFoundation
import Combine
import SwiftUI
import UIKit
import os

private let cameraLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.camera_p2p", category: "CameraService")

@MainActor
class LiveKitCameraService: NSObject, ObservableObject {

    @Published var room: Room?
    @Published var isConnected = false
    @Published var isPublishing = false
    @Published var errorMessage: String?

    @Published private(set) var cameraTrack: LocalVideoTrack?
    private var videoPublication: LocalTrackPublication?

    // Continuation dùng để chờ delegate báo camera track sẵn sàng.
    private var trackReadyContinuation: CheckedContinuation<LocalVideoTrack?, Never>?

    let serverURL: String
    let token: String
    let roomName: String

    // MARK: - Photo Capture Properties
    private let photoOutput = AVCapturePhotoOutput()
    // Trả về Data? — nil nếu chụp thất bại, jpeg data nếu thành công.
    private var captureContinuation: CheckedContinuation<Data?, Never>?

    // Callback được gọi sau khi chụp ảnh thành công (dù local hay remote).
    // View gán closure này để xử lý tiếp — ví dụ: gửi Telegram.
    var onPhotoReady: ((Data) async -> Void)?

    // MARK: - Camera State
    @Published var zoomFactor: CGFloat = 1.0
    var maxZoomFactor: CGFloat = 8.0
    @Published private(set) var isSwitchingCamera = false

    // MARK: - Microphone State
    @Published var isMicEnabled: Bool = false

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
            cameraLogger.error("❌ Zoom error: \(error)")
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
                    dimensions: .h480_43,
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
            self.isConnected = true
            cameraLogger.info("✅ Connected to room: \(self.roomName)")

        } catch {
            cameraLogger.error("❌ connect() threw: \(String(describing: error))")
            errorMessage = "Kết nối thất bại: \(String(describing: error))"
        }
    }

    func startPublishingCamera() async {
        guard let room = room, cameraTrack == nil else { return }

        do {
            try await room.localParticipant.setCamera(enabled: true)
        } catch {
            errorMessage = "Publish camera failed: \(error)"
            cameraLogger.error("❌ setCamera failed: \(error)")
            return
        }

        // Kiểm tra ngay nếu track đã sẵn sàng (trường hợp SDK trả về đồng bộ)
        if let existing = room.localParticipant.firstCameraVideoTrack as? LocalVideoTrack {
            cameraLogger.debug("✅ Camera track ready immediately")
            self.cameraTrack = existing
            setupPhotoOutput()
            isPublishing = true
            return
        }

        // Chờ delegate didPublishTrack báo track sẵn sàng, timeout 2 giây.
        // Tránh polling — SDK sẽ gọi callback khi track thực sự được publish.
        cameraLogger.debug("⏳ Waiting for camera track via delegate...")
        let track = await withCheckedContinuation { (continuation: CheckedContinuation<LocalVideoTrack?, Never>) in
            self.trackReadyContinuation = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    guard let self, let cont = self.trackReadyContinuation else { return }
                    cameraLogger.warning("⚠️ Camera track timeout sau 2 giây")
                    cont.resume(returning: nil)
                    self.trackReadyContinuation = nil
                }
            }
        }

        guard let track else {
            errorMessage = "Camera track không khởi động được sau 2 giây."
            return
        }

        self.cameraTrack = track
        setupPhotoOutput()
        isPublishing = true
        cameraLogger.info("✅ Camera publishing started")

        // Bật microphone cùng lúc với camera
        await enableMicrophone()
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
            try await room.localParticipant.setMicrophone(enabled: false)
        } catch {
            cameraLogger.error("⚠️ Unpublish error: \(error)")
        }
        cameraTrack = nil
        isPublishing = false
        isMicEnabled = false
    }

    func toggleMicrophone() {
        Task { await setMicrophone(enabled: !isMicEnabled) }
    }

    private func enableMicrophone() async {
        await setMicrophone(enabled: true)
    }

    private func setMicrophone(enabled: Bool) async {
        guard let room = room else { return }
        do {
            try await room.localParticipant.setMicrophone(enabled: enabled)
            isMicEnabled = enabled
            cameraLogger.info("\(enabled ? "🎙️ Microphone ON" : "🔇 Microphone OFF")")
        } catch {
            cameraLogger.error("❌ setMicrophone(\(enabled)) failed: \(error)")
        }
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

            cameraLogger.debug("✅ Đã inject AVCapturePhotoOutput vào LiveKit session")
        }

        session.commitConfiguration()
    }

    // MARK: - Capture

    /// Chụp ảnh và lưu vào thư viện. Trả về JPEG Data để caller dùng tiếp (vd: gửi Telegram).
    /// Trả về nil nếu chụp thất bại.
    func captureAndSavePhoto() async -> Data? {
        guard photoOutput.connections.count > 0 else {
            self.errorMessage = "Camera chưa sẵn sàng để chụp ảnh."
            return nil
        }

        cameraLogger.debug("📸 Đang yêu cầu cảm biến chụp ảnh...")

        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = self.photoOutput.maxPhotoQualityPrioritization

        // FIX: isHighResolutionPhotoEnabled deprecated từ iOS 16.
        if #unavailable(iOS 16.0) {
            if photoOutput.isHighResolutionCaptureEnabled {
                settings.isHighResolutionPhotoEnabled = true
            }
        }

        return await withCheckedContinuation { continuation in
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
            // Xác định kết quả: trả về Data nếu thành công, nil nếu lỗi.
            let result: Data?

            if let error = error {
                self.errorMessage = "Lỗi phần cứng chụp ảnh: \(error.localizedDescription)"
                result = nil
            } else if let fileData = photo.fileDataRepresentation(),
                      let image = UIImage(data: fileData) {
                // Lưu vào Photos (fire-and-forget, lỗi được báo qua handleSaveResult)
                UIImageWriteToSavedPhotosAlbum(
                    image,
                    self,
                    #selector(handleSaveResult(_:didFinishSavingWithError:contextInfo:)),
                    nil
                )
                result = fileData
            } else {
                self.errorMessage = "Lỗi xử lý file ảnh."
                result = nil
            }

            // Resume continuation — luôn chạy dù result là nil để tránh deadlock.
            self.captureContinuation?.resume(returning: result)
            self.captureContinuation = nil
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
                cameraLogger.error("❌ Lưu ảnh thất bại: \(error)")
            } else {
                cameraLogger.info("✅ Đã lưu ảnh vào thư viện thành công")
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
        cameraLogger.debug("🔄 Camera connection: \(String(describing: oldState)) → \(String(describing: state))")
        if state == .disconnected {
            cameraLogger.warning("⚠️ Disconnected from room")
            Task { @MainActor in self.isConnected = false }
        }
    }

    // Được gọi khi local participant publish một track thành công.
    // Resume continuation để startPublishingCamera() không cần polling.
    nonisolated func room(_ room: Room,
                          localParticipant: LocalParticipant,
                          didPublishTrack publication: LocalTrackPublication) {
        guard let videoTrack = publication.track as? LocalVideoTrack else { return }
        cameraLogger.debug("📡 Local camera track published via delegate")
        Task { @MainActor in
            guard let cont = self.trackReadyContinuation else { return }
            cont.resume(returning: videoTrack)
            self.trackReadyContinuation = nil
        }
    }

    nonisolated func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        let detail = error.map { String(describing: $0) } ?? "nil — server đóng kết nối không có lý do cụ thể"
        cameraLogger.error("❌ didFailToConnectWithError: \(detail)")
        Task { @MainActor in self.errorMessage = "Kết nối thất bại: \(detail)" }
    }

    nonisolated func room(_ room: Room,
                          participant: RemoteParticipant?,
                          didReceiveData data: Data,
                          forTopic topic: String,
                          encryptionType: EncryptionType) {
        guard topic == "camera_control",
              let command = String(data: data, encoding: .utf8) else { return }
        cameraLogger.debug("📨 Nhận lệnh từ viewer: \(command)")
        if command == "switch_camera" {
            Task { @MainActor in self.switchCamera() }
        } else if command == "capture_photo" {
            Task { @MainActor in
                guard let data = await self.captureAndSavePhoto() else { return }
                await self.onPhotoReady?(data)
            }
        } else if command.hasPrefix("zoom:"),
                  let factor = Double(command.dropFirst(5)) {
            Task { @MainActor in self.setZoom(factor: CGFloat(factor)) }
        }
    }
}
