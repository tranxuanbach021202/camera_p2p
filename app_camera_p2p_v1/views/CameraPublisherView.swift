//
//  CameraPublisherView.swift
//  app_camera_p2p_v1
//

import SwiftUI
import LiveKit
import Combine

struct CameraPublisherView: View {

    @StateObject private var service: LiveKitCameraService
    @StateObject private var telegramService: TelegramService

    @State private var isCapturing: Bool = false
    @State private var baseZoom: CGFloat = 1.0

    // MARK: - Controls Visibility
    @State private var isControlsVisible: Bool = true

    // MARK: - Screen Lock
    @State private var isScreenLocked: Bool = false
    @State private var unlockProgress: CGFloat = 0
    @State private var unlockTimer: Timer? = nil
    @State private var isHoldingToUnlock: Bool = false

    init(serverURL: String, cameraToken: String, telegramBotToken: String, telegramChatId: String) {
        _service = StateObject(wrappedValue: LiveKitCameraService(
            serverURL: serverURL,
            token: cameraToken,
            roomName: "alfred-room"
        ))
        _telegramService = StateObject(wrappedValue: TelegramService(
            botToken: telegramBotToken,
            chatId: telegramChatId
        ))
    }

    // Nút bị khoá khi đang chụp ảnh, đang switch camera, hoặc đang gửi Telegram.
    private var isLocked: Bool {
        isCapturing || service.isSwitchingCamera || telegramService.isSending
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // MARK: Camera Preview
            if let track = service.cameraTrack {
                SwiftUIVideoView(track, layoutMode: .fit)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let newZoom = baseZoom * value
                                service.setZoom(factor: newZoom)
                            }
                            .onEnded { _ in
                                baseZoom = service.zoomFactor
                            }
                    )
            } else {
                Color.black
                    .overlay {
                        VStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text(service.isConnected ? "Starting camera..." : "Camera not publishing")
                                .foregroundColor(.white)
                        }
                    }
            }

            // MARK: Controls Overlay
            VStack {
                Spacer()

                if isControlsVisible {
                    if service.isPublishing {
                        ZoomControlBar(
                            zoomFactor: service.zoomFactor,
                            maxZoom: service.maxZoomFactor,
                            onZoomChange: { newZoom in
                                service.setZoom(factor: newZoom)
                                baseZoom = newZoom
                            }
                        )
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        .opacity(isCapturing ? 0 : 1.0)
                    }

                    HStack(spacing: 20) {
                        Button(service.isPublishing ? "Stop Stream" : "Start Stream") {
                            Task {
                                if service.isPublishing {
                                    await service.stopPublishing()
                                } else {
                                    await service.connect()
                                    if service.isConnected {
                                        await service.startPublishingCamera()
                                    }
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isLocked)

                        if service.isPublishing {
                            // Nút chụp ảnh
                            Button {
                                Task {
                                    withAnimation(.easeInOut(duration: 0.2)) { isCapturing = true }
                                    let imageData = await service.captureAndSavePhoto()
                                    withAnimation(.easeInOut(duration: 0.2)) { isCapturing = false }
                                    if let imageData {
                                        await service.onPhotoReady?(imageData)
                                    }
                                }
                            } label: {
                                Image(systemName: "camera.circle.fill")
                                    .font(.system(size: 44))
                                    .foregroundColor(.white)
                                    .background(Circle().fill(Color.black.opacity(0.3)))
                            }
                            .disabled(isLocked)

                            // Nút đổi camera
                            Button {
                                service.switchCamera()
                                baseZoom = 1.0
                                service.setZoom(factor: 1.0)
                            } label: {
                                if service.isSwitchingCamera {
                                    ProgressView().frame(width: 20, height: 20)
                                } else {
                                    Image(systemName: "camera.rotate")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isLocked)

                            // Nút mute/unmute mic
                            Button {
                                service.toggleMicrophone()
                            } label: {
                                Image(systemName: service.isMicEnabled ? "mic.fill" : "mic.slash.fill")
                                    .font(.title2)
                                    .foregroundColor(service.isMicEnabled ? .green : .red)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isLocked)

                            // Nút khoá màn hình
                            Button {
                                withAnimation(.easeInOut(duration: 0.3)) { isScreenLocked = true }
                            } label: {
                                Image(systemName: "lock.fill")
                                    .font(.title2)
                                    .foregroundColor(.white)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isLocked)
                        }

                        Button("Disconnect") {
                            Task { await service.disconnect() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isLocked)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Nút toggle ẩn/hiện controls — luôn hiển thị
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        isControlsVisible.toggle()
                    }
                } label: {
                    Image(systemName: isControlsVisible ? "chevron.down" : "chevron.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 20)
                        .background(.black.opacity(0.4), in: Capsule())
                }
                .padding(.bottom, 8)
            }

            // MARK: Loading Overlay (chụp ảnh + gửi Telegram)
            if isCapturing || telegramService.isSending {
                ZStack {
                    Color.black.opacity(0.6)
                        .edgesIgnoringSafeArea(.all)

                    VStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)

                        Text(telegramService.isSending ? "Đang gửi Telegram..." : "Đang lưu ảnh...")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white)
                    }
                }
                .transition(.opacity)
            }

            // MARK: Screen Lock Overlay
            if isScreenLocked {
                Color.black
                    .ignoresSafeArea()
                    .overlay {
                        VStack(spacing: 24) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 52))
                                .foregroundColor(.white.opacity(0.1))

                            Text("Màn hình đã khoá")
                                .font(.headline)
                                .foregroundColor(.white.opacity(0.1))

                            Text("Nhấn giữ 5 giây để mở khoá")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.1))

                            // Vòng tròn tiến trình mở khoá
                            ZStack {
                                Circle()
                                    .stroke(Color.white.opacity(0.1), lineWidth: 5)
                                Circle()
                                    .trim(from: 0, to: unlockProgress)
                                    .stroke(Color.white.opacity(isHoldingToUnlock ? 0.9 : 0), lineWidth: 5)
                                    .rotationEffect(.degrees(-90))
                                    .animation(.linear(duration: 0.05), value: unlockProgress)
                                Image(systemName: isHoldingToUnlock ? "lock.open.fill" : "lock.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(.white.opacity(isHoldingToUnlock ? 0.9 : 0.1))
                            }
                            .frame(width: 70, height: 70)
                            .padding(.top, 8)
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in startUnlockCountdown() }
                            .onEnded { _ in cancelUnlockCountdown() }
                    )
                    .transition(.opacity)
            }
        }
        .navigationBarBackButtonHidden(isScreenLocked)
        .toolbar(isScreenLocked ? .hidden : .visible, for: .navigationBar)
        .statusBarHidden(isScreenLocked)
        .onAppear {
            // Gán callback: mọi ảnh chụp (local hoặc remote từ viewer) đều đi qua đây
            service.onPhotoReady = { [telegramService] data in
                guard telegramService.isConfigured else { return }
                let f = DateFormatter()
                f.dateFormat = "dd/MM/yyyy HH:mm:ss"
                let caption = "📷 Camera P2P — \(f.string(from: Date()))"
                await telegramService.sendPhoto(data, caption: caption)
            }
            Task {
                await service.connect()
                if service.isConnected {
                    await service.startPublishingCamera()
                }
            }
        }
        .onDisappear {
            Task { await service.disconnect() }
        }
        .alert("Error", isPresented: .constant(service.errorMessage != nil)) {
            Button("OK") { service.errorMessage = nil }
        } message: {
            Text(service.errorMessage ?? "")
        }
        .alert("Telegram", isPresented: .constant(telegramService.lastError != nil)) {
            Button("OK") { telegramService.lastError = nil }
        } message: {
            Text(telegramService.lastError ?? "")
        }
    }

    // MARK: - Helpers

    private func formattedNow() -> String {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy HH:mm:ss"
        return f.string(from: Date())
    }

    // MARK: - Screen Lock Helpers

    private func startUnlockCountdown() {
        guard unlockTimer == nil else { return }
        isHoldingToUnlock = true
        let start = Date()
        unlockTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            let elapsed = Date().timeIntervalSince(start)
            let progress = CGFloat(elapsed / 5.0)
            DispatchQueue.main.async {
                unlockProgress = min(progress, 1.0)
                if elapsed >= 5.0 {
                    timer.invalidate()
                    unlockTimer = nil
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isScreenLocked = false
                        unlockProgress = 0
                        isHoldingToUnlock = false
                    }
                }
            }
        }
    }

    private func cancelUnlockCountdown() {
        unlockTimer?.invalidate()
        unlockTimer = nil
        withAnimation(.easeOut(duration: 0.2)) {
            unlockProgress = 0
            isHoldingToUnlock = false
        }
    }
}

// MARK: - Zoom Control Bar

struct ZoomControlBar: View {
    let zoomFactor: CGFloat
    let maxZoom: CGFloat
    let onZoomChange: (CGFloat) -> Void

    private let presets: [CGFloat] = [1.0, 2.0, 3.0, 5.0]

    var body: some View {
        VStack(spacing: 8) {
            Text(String(format: "%.1fx", zoomFactor))
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())

            HStack(spacing: 12) {
                Button {
                    let newZoom = max(zoomFactor - 0.5, 1.0)
                    onZoomChange(newZoom)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.title3)
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }

                Slider(
                    value: Binding(
                        get: { zoomFactor },
                        set: { onZoomChange($0) }
                    ),
                    in: 1.0...max(maxZoom, 1.0),
                    step: 0.1
                )
                .tint(.white)

                Button {
                    let newZoom = min(zoomFactor + 0.5, maxZoom)
                    onZoomChange(newZoom)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.title3)
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }

            HStack(spacing: 8) {
                ForEach(presets.filter { $0 <= maxZoom }, id: \.self) { preset in
                    Button {
                        onZoomChange(preset)
                    } label: {
                        Text("\(Int(preset))x")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(abs(zoomFactor - preset) < 0.1 ? .black : .white)
                            .frame(width: 36, height: 28)
                            .background(
                                abs(zoomFactor - preset) < 0.1 ? Color.white : Color.white.opacity(0.2),
                                in: Capsule()
                            )
                    }
                }
            }
        }
        .padding(12)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }
}
