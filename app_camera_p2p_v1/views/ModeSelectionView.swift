//
//  ModeSelectionView.swift
//  app_camera_p2p_v1
//

import SwiftUI

// MARK: - Allowed Mode

enum AllowedMode: Identifiable {
    case cameraOnly, viewerOnly
    var id: Self { self }
}

// MARK: - Key Entry View

struct KeyEntryView: View {

    let serverURL: String
    let cameraToken: String
    let viewerToken: String

    @State private var keyText: String = ""
    @State private var allowedMode: AllowedMode? = nil
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color.black, Color(white: 0.1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 48) {

                    // Header
                    VStack(spacing: 12) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.white)

                        Text("Camera P2P")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(.white)

                        Text("Nhập mã để tiếp tục")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.6))
                    }

                    // Input
                    VStack(spacing: 12) {
                        TextField("Nhập mã truy cập...", text: $keyText)
                            .focused($isFieldFocused)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                            .tint(.white)
                            .padding(16)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
                            )
                            .onSubmit { confirm() }

                        Button(action: confirm) {
                            Text("Tiếp tục")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(.horizontal, 32)
                }
            }
            .onAppear { isFieldFocused = true }
            .navigationDestination(item: $allowedMode) { mode in
                ModeSelectionView(
                    serverURL: serverURL,
                    cameraToken: cameraToken,
                    viewerToken: viewerToken,
                    allowedMode: mode
                )
                .navigationBarBackButtonHidden(false)
            }
        }
    }

    private func confirm() {
        isFieldFocused = false
        allowedMode = keyText == "camera" ? .cameraOnly : .viewerOnly
    }
}

// MARK: - Mode Selection View

struct ModeSelectionView: View {

    let serverURL: String
    let cameraToken: String
    let viewerToken: String
    let allowedMode: AllowedMode

    @State private var selectedMode: AppMode? = nil

    enum AppMode {
        case camera, viewer
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(white: 0.1)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 48) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.white)

                    Text("Camera P2P")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.white)

                    Text("Chọn chế độ để bắt đầu")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.6))
                }

                // Mode Buttons
                VStack(spacing: 16) {
                    ModeButton(
                        icon: "camera.fill",
                        title: "Camera",
                        subtitle: "Phát trực tiếp từ camera",
                        color: .blue,
                        isDisabled: allowedMode == .viewerOnly
                    ) {
                        selectedMode = .camera
                    }

                    ModeButton(
                        icon: "eye.fill",
                        title: "Viewer",
                        subtitle: "Xem camera từ xa",
                        color: .green,
                        isDisabled: allowedMode == .cameraOnly
                    ) {
                        selectedMode = .viewer
                    }
                }
                .padding(.horizontal, 32)
            }
        }
        .navigationDestination(item: $selectedMode) { mode in
            switch mode {
            case .camera:
                CameraPublisherView(
                    serverURL: serverURL,
                    cameraToken: cameraToken
                )
                .navigationBarBackButtonHidden(false)

            case .viewer:
                CameraViewerView(
                    serverURL: serverURL,
                    viewerToken: viewerToken
                )
                .navigationBarBackButtonHidden(false)
            }
        }
    }
}

// MARK: - Mode Button Component

struct ModeButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let isDisabled: Bool
    let action: () -> Void

    @State private var isPressed = false

    private var effectiveColor: Color { isDisabled ? .gray : color }
    private var opacity: Double { isDisabled ? 0.35 : 1.0 }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(effectiveColor.opacity(0.2))
                        .frame(width: 56, height: 56)

                    Image(systemName: icon)
                        .font(.system(size: 24))
                        .foregroundColor(effectiveColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.6))
                }

                Spacer()

                Image(systemName: isDisabled ? "lock.fill" : "chevron.right")
                    .foregroundColor(.white.opacity(isDisabled ? 0.25 : 0.4))
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(isDisabled ? 0.03 : 0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(effectiveColor.opacity(isDisabled ? 0.1 : 0.3), lineWidth: 1)
                    )
            )
            .opacity(opacity)
            .scaleEffect(isPressed && !isDisabled ? 0.97 : 1.0)
            .animation(.spring(response: 0.2), value: isPressed)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !isDisabled { isPressed = true } }
                .onEnded { _ in isPressed = false }
        )
    }
}

// MARK: - Hashable conformance

extension ModeSelectionView.AppMode: Hashable {}
