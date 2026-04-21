//
//  LiveKitViewerService.swift
//  app_camera_p2p_v1
//

import LiveKit
import AVFoundation
import Combine
import SwiftUI
import os

private let viewerLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.camera_p2p", category: "ViewerService")

// MARK: - Mic Info Model

struct MicInfo: Identifiable, Decodable, Equatable {
    let uid: String
    let name: String
    let active: Bool
    var id: String { uid }
}

@MainActor
class LiveKitViewerService: ObservableObject {
    
    @Published var isConnected = false
    @Published var isReceiving = false
    @Published var isSwitchingCamera = false
    @Published var isCapturing = false
    @Published var zoomFactor: CGFloat = 1.0
    let maxZoomFactor: CGFloat = 8.0
    @Published var isSpeakerEnabled: Bool = true
    @Published var errorMessage: String?
    @Published private(set) var remoteVideoTrack: VideoTrack?
    /// Danh sách mic nhận từ camera qua data channel (chỉ có khi có Bluetooth HFP).
    @Published var availableMics: [MicInfo] = []
    /// Trạng thái khoá màn hình của camera, đồng bộ qua data channel.
    @Published var isCameraLocked: Bool = false
    /// Mic của camera đang tắt (muted) hay bật.
    @Published var isCameraMicMuted: Bool = true
    /// Toạ độ focus hiện tại trong view (dùng để hiển thị ring animation).
    @Published var focusPoint: CGPoint? = nil
    /// Giá trị exposure bias đang được áp dụng trên camera (-2.0 ~ +2.0 EV).
    @Published var exposureBias: Float = 0.0
    /// Chất lượng stream hiện tại, đồng bộ từ camera.
    @Published var streamQuality: StreamQuality = .mid
    /// Viewer đã nhấn "Cho phép mở khoá" — camera cần cả cờ này lẫn giữ 5s.
    @Published var hasGrantedUnlock: Bool = false
    
    private var room: Room?
    let serverURL: String
    let token: String
    
    init(serverURL: String, token: String) {
        self.serverURL = serverURL
        self.token = token
    }
    
    func connect() async {
        do {
            let newRoom = Room(delegate: self)
            
            // autoSubscribe = true: SDK sẽ tự động subscribe vào các track (bao gồm các track đã có sẵn từ trước)
            let connectOptions = ConnectOptions(
                autoSubscribe: true
            )
            
            try await newRoom.connect(
                url: serverURL,
                token: token,
                connectOptions: connectOptions
            )
            
            self.room = newRoom
            self.isConnected = true
            viewerLogger.info("✅ Viewer connected to room")

            // Route audio ra loa ngoài (mặc định iOS dùng tai nghe/earpiece)
            routeAudioToSpeaker(isSpeakerEnabled)

            // Lấy track ngay lập tức nếu camera đã phát trước khi viewer vào
            checkAndAssignExistingTrack(in: newRoom)
            
        } catch {
            errorMessage = "Connect failed: \(error.localizedDescription)"
            viewerLogger.error("❌ Viewer connect error: \(error)")
        }
    }
    
    func sendSwitchCameraCommand() async {
        guard let room = room, isConnected, !isSwitchingCamera else { return }
        do {
            isSwitchingCamera = true
            let data = "switch_camera".data(using: .utf8)!
            try await room.localParticipant.publish(
                data: data,
                options: DataPublishOptions(topic: "camera_control", reliable: true)
            )
            viewerLogger.debug("📤 Đã gửi lệnh switch_camera")
            // Cooldown 2.5s để tránh gửi liên tục trong khi camera đang xoay
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            isSwitchingCamera = false
        } catch {
            isSwitchingCamera = false
            errorMessage = "Không gửi được lệnh: \(error.localizedDescription)"
        }
    }

    func toggleSpeaker() {
        isSpeakerEnabled.toggle()
        routeAudioToSpeaker(isSpeakerEnabled)
    }

    private func routeAudioToSpeaker(_ speaker: Bool) {
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(speaker ? .speaker : .none)
            viewerLogger.info("🔊 Audio route → \(speaker ? "speaker" : "default")")
        } catch {
            viewerLogger.error("❌ Audio route error: \(error)")
        }
    }

    func sendZoomCommand(factor: CGFloat) async {
        guard let room = room, isConnected else { return }
        let clamped = min(max(factor, 1.0), maxZoomFactor)
        zoomFactor = clamped
        let command = String(format: "zoom:%.3f", clamped)
        guard let data = command.data(using: .utf8) else { return }
        // reliable: false — zoom là real-time, ưu tiên tốc độ hơn đảm bảo giao hàng
        try? await room.localParticipant.publish(
            data: data,
            options: DataPublishOptions(topic: "camera_control", reliable: false)
        )
    }

    func sendCapturePhotoCommand() async {
        guard let room = room, isConnected, !isCapturing else { return }
        do {
            isCapturing = true
            let data = "capture_photo".data(using: .utf8)!
            try await room.localParticipant.publish(
                data: data,
                options: DataPublishOptions(topic: "camera_control", reliable: true)
            )
            viewerLogger.debug("📤 Đã gửi lệnh capture_photo")
            // Cooldown 3s — đủ để camera hoàn tất chụp và lưu ảnh
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            isCapturing = false
        } catch {
            isCapturing = false
            errorMessage = "Không gửi được lệnh chụp ảnh: \(error.localizedDescription)"
        }
    }

    func disconnect() async {
        await room?.disconnect()
        remoteVideoTrack = nil
        isConnected = false
        isReceiving = false
        room = nil
        viewerLogger.info("🔌 Viewer disconnected")
    }
    
    // Hàm này quét xem trong room đã có video track nào chưa để hiển thị luôn
    private func checkAndAssignExistingTrack(in room: Room) {
        for participant in room.remoteParticipants.values {
            for publication in participant.videoTracks {
                if let track = publication.track as? VideoTrack {
                    self.remoteVideoTrack = track
                    self.isReceiving = true
                    viewerLogger.debug("🎥 Found existing video track and assigned")
                    return // Chỉ lấy track đầu tiên
                }
            }
        }
    }
}

// MARK: - RoomDelegate
extension LiveKitViewerService: RoomDelegate {

    nonisolated func room(_ room: Room,
                          didUpdateConnectionState state: ConnectionState,
                          from oldState: ConnectionState) {
        viewerLogger.debug("🔄 Viewer connection: \(String(describing: oldState)) → \(String(describing: state))")
        if state == .disconnected {
            Task { @MainActor in
                self.isConnected = false
                self.isReceiving = false
            }
        }
    }
    
    // [ĐÃ SỬA] - Dùng didPublishTrack
    nonisolated func room(_ room: Room,
                          participant: RemoteParticipant,
                          didPublishTrack publication: RemoteTrackPublication) {
        viewerLogger.debug("📡 Remote track published: \(String(describing: publication.kind))")
    }
    
    // LiveKit 2.x: delegate không có tham số track, lấy qua publication.track
    nonisolated func room(_ room: Room,
                          participant: RemoteParticipant,
                          didSubscribeTrack publication: RemoteTrackPublication) {
        guard let videoTrack = publication.track as? VideoTrack else { return }
        viewerLogger.info("🎥 Video track subscribed and ready")
        Task { @MainActor in
            self.remoteVideoTrack = videoTrack
            self.isReceiving = true
            // Yêu cầu camera gửi danh sách mic ngay khi nhận được stream
            await self.requestMicList()
        }
    }

    nonisolated func room(_ room: Room,
                          participant: RemoteParticipant,
                          didUnsubscribeTrack publication: RemoteTrackPublication) {
        viewerLogger.info("📴 Remote track unsubscribed")
        Task { @MainActor in
            if publication.kind == .video {
                self.remoteVideoTrack = nil
                self.isReceiving = false
            }
        }
    }

    nonisolated func room(_ room: Room,
                          participant: RemoteParticipant,
                          didUnpublishTrack publication: RemoteTrackPublication) {
        viewerLogger.info("📴 Remote track unpublished")
        Task { @MainActor in
            if publication.kind == .video {
                self.remoteVideoTrack = nil
                self.isReceiving = false
            }
        }
    }
    
    nonisolated func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        let msg = error?.localizedDescription ?? "Unknown error"
        Task { @MainActor in
            self.errorMessage = "Failed to connect: \(msg)"
        }
    }

    /// Nhận data từ camera — xử lý mic_list push từ camera.
    nonisolated func room(_ room: Room,
                          participant: RemoteParticipant?,
                          didReceiveData data: Data,
                          forTopic topic: String,
                          encryptionType: EncryptionType) {
        guard topic == "camera_control",
              let command = String(data: data, encoding: .utf8) else { return }

        if command.hasPrefix("mic_list:") {
            let jsonStr = String(command.dropFirst(9))
            guard let jsonData = jsonStr.data(using: .utf8),
                  let mics = try? JSONDecoder().decode([MicInfo].self, from: jsonData) else {
                viewerLogger.warning("⚠️ Không parse được mic_list JSON")
                return
            }
            viewerLogger.debug("🎙️ Nhận mic list: \(mics.count) thiết bị")
            Task { @MainActor in self.availableMics = mics }
        } else if command.hasPrefix("lock_state:") {
            let locked = command.dropFirst(11) == "1"
            viewerLogger.debug("🔒 Camera lock state: \(locked)")
            Task { @MainActor in
                self.isCameraLocked = locked
                if !locked { self.hasGrantedUnlock = false }  // Camera đã mở → reset quyền
            }
        } else if command.hasPrefix("mic_state:") {
            let enabled = command.dropFirst(10) == "1"
            Task { @MainActor in self.isCameraMicMuted = !enabled }
        } else if command.hasPrefix("exposure_state:"),
                  let bias = Float(command.dropFirst(15)) {
            Task { @MainActor in self.exposureBias = bias }
        } else if command.hasPrefix("quality_state:"),
                  let quality = StreamQuality(rawValue: String(command.dropFirst(14))) {
            Task { @MainActor in self.streamQuality = quality }
        }
    }
}

// MARK: - Mic Control

extension LiveKitViewerService {

    /// Yêu cầu camera gửi lại danh sách mic hiện tại.
    func requestMicList() async {
        guard let room = room, isConnected else { return }
        guard let data = "request_mic_list".data(using: .utf8) else { return }
        try? await room.localParticipant.publish(
            data: data,
            options: DataPublishOptions(topic: "camera_control", reliable: true)
        )
    }

    /// Gửi lệnh chuyển chất lượng stream (fps preset).
    func sendQualityCommand(_ quality: StreamQuality) async {
        guard let room = room, isConnected else { return }
        guard let data = "quality:\(quality.rawValue)".data(using: .utf8) else { return }
        try? await room.localParticipant.publish(
            data: data,
            options: DataPublishOptions(topic: "camera_control", reliable: true)
        )
        viewerLogger.debug("📹 Gửi quality: \(quality.label)")
    }

    /// Gửi lệnh điều chỉnh exposure bias (-2.0 ~ +2.0 EV).
    func sendExposureCommand(_ bias: Float) async {
        guard let room = room, isConnected else { return }
        let cmd = String(format: "exposure:%.2f", bias)
        guard let data = cmd.data(using: .utf8) else { return }
        try? await room.localParticipant.publish(
            data: data,
            options: DataPublishOptions(topic: "camera_control", reliable: false)
        )
    }

    /// Gửi lệnh tap-to-focus với toạ độ chuẩn hoá (0–1) và hiển thị ring animation.
    func sendFocusCommand(viewPoint: CGPoint, viewSize: CGSize) async {
        guard let room = room, isConnected, viewSize.width > 0, viewSize.height > 0 else { return }
        let nx = viewPoint.x / viewSize.width
        let ny = viewPoint.y / viewSize.height
        let cmd = String(format: "focus:%.4f,%.4f", nx, ny)
        guard let data = cmd.data(using: .utf8) else { return }
        try? await room.localParticipant.publish(
            data: data,
            options: DataPublishOptions(topic: "camera_control", reliable: false)
        )
        // Hiển thị focus ring tại điểm chạm, tự ẩn sau 1.5s
        focusPoint = viewPoint
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { self.focusPoint = nil }
        }
        viewerLogger.debug("🎯 Focus → (\(String(format: "%.2f", nx)), \(String(format: "%.2f", ny)))")
    }

    /// Mute hoặc unmute mic của camera.
    func sendMicMuteCommand(muted: Bool) async {
        guard let room = room, isConnected else { return }
        let cmd = muted ? "mic_mute" : "mic_unmute"
        guard let data = cmd.data(using: .utf8) else { return }
        try? await room.localParticipant.publish(
            data: data,
            options: DataPublishOptions(topic: "camera_control", reliable: true)
        )
        viewerLogger.debug("📤 \(muted ? "🔇 Mute" : "🎙️ Unmute") mic camera")
    }

    /// Gửi lệnh chọn mic tới camera theo UID.
    func sendSelectMicCommand(uid: String) async {
        guard let room = room, isConnected else { return }
        guard let data = "mic:\(uid)".data(using: .utf8) else { return }
        try? await room.localParticipant.publish(
            data: data,
            options: DataPublishOptions(topic: "camera_control", reliable: true)
        )
        viewerLogger.debug("📤 Đã gửi lệnh chọn mic: \(uid)")
    }

    /// Gửi lệnh khoá màn hình camera.
    func sendLockScreen() async {
        guard let room = room, isConnected else { return }
        guard let data = "lock_screen".data(using: .utf8) else { return }
        try? await room.localParticipant.publish(
            data: data,
            options: DataPublishOptions(topic: "camera_control", reliable: true)
        )
        viewerLogger.debug("🔒 Đã gửi lệnh lock_screen")
    }

    /// Cho phép camera mở khoá — camera vẫn cần giữ 5s để hoàn tất.
    func sendAllowUnlock() async {
        guard let room = room, isConnected else { return }
        guard let data = "allow_unlock".data(using: .utf8) else { return }
        try? await room.localParticipant.publish(
            data: data,
            options: DataPublishOptions(topic: "camera_control", reliable: true)
        )
        hasGrantedUnlock = true
        viewerLogger.debug("🔓 Đã gửi allow_unlock")
    }

    /// Huỷ quyền mở khoá đã cấp trước đó.
    func sendRevokeUnlock() async {
        guard let room = room, isConnected else { return }
        guard let data = "revoke_unlock".data(using: .utf8) else { return }
        try? await room.localParticipant.publish(
            data: data,
            options: DataPublishOptions(topic: "camera_control", reliable: true)
        )
        hasGrantedUnlock = false
        viewerLogger.debug("🔒 Đã gửi revoke_unlock")
    }
}
