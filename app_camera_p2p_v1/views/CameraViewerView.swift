//
//  CameraViewerView.swift
//  app_camera_p2p_v1
//
//  Created by Bach Xuan on 15/4/26.
//

//
//  CameraViewerView.swift
//  app_camera_p2p_v1
//

import SwiftUI
import LiveKit

struct CameraViewerView: View {
    
    @StateObject private var service: LiveKitViewerService
    @Environment(\.dismiss) private var dismiss
    @State private var baseZoom: CGFloat = 1.0
    @State private var showMicPicker = false
    
    init(serverURL: String, viewerToken: String) {
        _service = StateObject(wrappedValue: LiveKitViewerService(
            serverURL: serverURL,
            token: viewerToken,
            
        ))
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // MARK: Video hoặc Waiting screen
            if let track = service.remoteVideoTrack {
                SwiftUIVideoView(track, layoutMode: .fit)
                    .ignoresSafeArea()
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let newZoom = baseZoom * value
                                Task { await service.sendZoomCommand(factor: newZoom) }
                            }
                            .onEnded { _ in
                                baseZoom = service.zoomFactor
                            }
                    )
            } else {
                WaitingForCameraView(isConnected: service.isConnected)
            }
            
            // MARK: Top status bar + Bottom controls
            VStack {
                // Top bar: Status (trái) — Nút X (phải)
                HStack {
                    StatusBadge(isConnected: service.isConnected, isReceiving: service.isReceiving)

                    Spacer()

                    // Disconnect button
                    Button {
                        Task {
                            await service.disconnect()
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                // Nút Lock giữa màn hình — cách xa nút X để tránh nhấn nhầm
                LockControlButton(service: service)
                    .padding(.top, 12)

                Spacer()

                // MARK: Bottom controls (chỉ hiện khi đang nhận stream)
                if service.isReceiving {
                    ZoomControlBar(
                        zoomFactor: service.zoomFactor,
                        maxZoom: service.maxZoomFactor,
                        onZoomChange: { newZoom in
                            Task { await service.sendZoomCommand(factor: newZoom) }
                            baseZoom = newZoom
                        }
                    )
                    .padding(.horizontal)
                    .padding(.bottom, 8)

                    HStack(spacing: 32) {
                        // Nút speaker on/off
                        Button {
                            service.toggleSpeaker()
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(.ultraThinMaterial)
                                    .frame(width: 56, height: 56)
                                Image(systemName: service.isSpeakerEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(service.isSpeakerEnabled ? .white : .red)
                            }
                        }

                        // Nút chọn mic Bluetooth — chỉ hiện khi camera có ≥1 Bluetooth HFP
                        if !service.availableMics.isEmpty {
                            Button {
                                showMicPicker = true
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(.ultraThinMaterial)
                                        .frame(width: 56, height: 56)
                                    Image(systemName: "mic.fill")
                                        .font(.system(size: 20))
                                        .foregroundStyle(.white)
                                }
                            }
                            .confirmationDialog("Chọn microphone", isPresented: $showMicPicker, titleVisibility: .visible) {
                                ForEach(service.availableMics) { mic in
                                    Button {
                                        Task { await service.sendSelectMicCommand(uid: mic.uid) }
                                    } label: {
                                        // Dấu checkmark cho mic đang active
                                        Text(mic.active ? "✓  \(mic.name)" : mic.name)
                                    }
                                }
                                Button("Huỷ", role: .cancel) {}
                            }
                        }

                        // Nút mute/unmute mic camera
                        Button {
                            Task { await service.sendMicMuteCommand(muted: !service.isCameraMicMuted) }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(.ultraThinMaterial)
                                    .frame(width: 56, height: 56)
                                Image(systemName: service.isCameraMicMuted ? "mic.slash.fill" : "mic.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(service.isCameraMicMuted ? .red : .white)
                            }
                        }

                        // Nút chụp ảnh
                        Button {
                            Task { await service.sendCapturePhotoCommand() }
                        } label: {
                            ZStack {
                                // Viền ngoài kiểu shutter
                                Circle()
                                    .stroke(Color.white.opacity(0.8), lineWidth: 3)
                                    .frame(width: 64, height: 64)
                                Circle()
                                    .fill(service.isCapturing ? Color.white.opacity(0.4) : Color.white.opacity(0.9))
                                    .frame(width: 54, height: 54)
                                if service.isCapturing {
                                    ProgressView()
                                        .tint(.black)
                                        .scaleEffect(0.9)
                                }
                            }
                        }
                        .disabled(service.isCapturing)

                        // Nút xoay camera
                        Button {
                            Task { await service.sendSwitchCameraCommand() }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(.ultraThinMaterial)
                                    .frame(width: 56, height: 56)
                                if service.isSwitchingCamera {
                                    ProgressView()
                                        .tint(.white)
                                        .scaleEffect(0.9)
                                } else {
                                    Image(systemName: "camera.rotate.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .disabled(service.isSwitchingCamera)
                    }
                    .padding(.bottom, 32)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .onAppear {
            Task { await service.connect() }
        }
        .onDisappear {
            Task { await service.disconnect() }
        }
        .alert("Error", isPresented: .constant(service.errorMessage != nil)) {
            Button("OK") { service.errorMessage = nil }
        } message: {
            Text(service.errorMessage ?? "")
        }
    }
}

// MARK: - Waiting View
struct WaitingForCameraView: View {
    let isConnected: Bool
    
    @State private var pulse = false
    
    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 120, height: 120)
                    .scaleEffect(pulse ? 1.3 : 1.0)
                    .opacity(pulse ? 0 : 0.5)
                    .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false), value: pulse)
                
                Circle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 90, height: 90)
                
                Image(systemName: isConnected ? "video.slash.fill" : "wifi.slash")
                    .font(.system(size: 36))
                    .foregroundColor(.white.opacity(0.6))
            }
            .onAppear { pulse = true }
            
            VStack(spacing: 8) {
                Text(isConnected ? "Đang chờ camera..." : "Đang kết nối...")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                
                Text(isConnected
                     ? "Camera chưa phát hoặc đã tắt"
                     : "Đang kết nối tới server")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Status Badge
struct StatusBadge: View {
    let isConnected: Bool
    let isReceiving: Bool
    
    var label: String {
        if isReceiving { return "LIVE" }
        if isConnected { return "Chờ" }
        return "Offline"
    }
    
    var color: Color {
        if isReceiving { return .red }
        if isConnected { return .orange }
        return .gray
    }
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: - Lock Control Button

struct LockControlButton: View {
    @ObservedObject var service: LiveKitViewerService

    var body: some View {
        Group {
            if !service.isCameraLocked {
                // Camera chưa khoá → nút Khoá
                Button {
                    Task { await service.sendLockScreen() }
                } label: {
                    LockLabel(icon: "lock.open.fill", text: "Khoá camera",
                              iconColor: .white.opacity(0.85), textColor: .white.opacity(0.7))
                }
            } else if !service.hasGrantedUnlock {
                // Camera đang khoá, chưa cho phép → nút Cho phép
                Button {
                    Task { await service.sendAllowUnlock() }
                } label: {
                    LockLabel(icon: "lock.fill", text: "Cho phép mở khoá",
                              iconColor: .yellow, textColor: .yellow.opacity(0.9))
                }
            } else {
                // Đã cho phép → nút Huỷ
                Button {
                    Task { await service.sendRevokeUnlock() }
                } label: {
                    LockLabel(icon: "lock.open.fill", text: "Huỷ cho phép",
                              iconColor: .orange, textColor: .orange.opacity(0.9))
                }
            }
        }
        .disabled(!service.isConnected)
    }
}

private struct LockLabel: View {
    let icon: String
    let text: String
    let iconColor: Color
    let textColor: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
