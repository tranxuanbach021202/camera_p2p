//
//  ImageStreamService.swift
//  app_camera_p2p_v1
//

import Foundation
import os
import Combine

private let imageStreamLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.camera_p2p",
    category: "ImageStreamService"
)

@MainActor
class ImageStreamService: ObservableObject {

    private let uploadURL = Config.ImageStream.uploadURL
    private let apiKey    = Config.ImageStream.apiKey

    @Published var isSending = false
    @Published var lastError: String?

    // MARK: - Upload

    /// Upload ảnh JPEG lên ImageStream API.
    /// - Parameters:
    ///   - imageData: Dữ liệu JPEG của ảnh.
    ///   - filename: Tên file tuỳ chọn; mặc định dùng timestamp.
    ///   - batteryPercent: Phần trăm pin thiết bị camera (0–100); nil nếu không xác định.
    func uploadPhoto(_ imageData: Data, filename: String? = nil, batteryPercent: Int? = nil) async {
        guard let url = URL(string: uploadURL) else {
            lastError = "URL không hợp lệ."
            return
        }

        isSending = true
        lastError = nil

        let fname = filename ?? "photo_\(Int(Date().timeIntervalSince1970)).jpg"
        let batteryLog = batteryPercent.map { "\($0)%" } ?? "N/A"
        imageStreamLogger.debug("📤 Đang upload ảnh lên ImageStream API (\(fname), pin: \(batteryLog))...")

        do {
            let request = buildRequest(url: url, imageData: imageData, filename: fname, batteryPercent: batteryPercent)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw ImageStreamError.invalidResponse
            }

            let body = String(data: data, encoding: .utf8) ?? "(empty)"

            if (200..<300).contains(http.statusCode) {
                imageStreamLogger.info("✅ Upload thành công — response: \(body)")
            } else {
                throw ImageStreamError.apiError("HTTP \(http.statusCode): \(body)")
            }
        } catch {
            lastError = "Upload thất bại: \(error.localizedDescription)"
            imageStreamLogger.error("❌ ImageStream upload error: \(error)")
        }

        isSending = false
    }

    // MARK: - Private

    private func buildRequest(url: URL, imageData: Data, filename: String, batteryPercent: Int?) -> URLRequest {
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("*/*", forHTTPHeaderField: "accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // field: image (file binary)
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: image/jpeg\r\n\r\n")
        body.append(imageData)
        body.append("\r\n")

        // field: battery (text) — phần trăm pin, gửi kèm khi có giá trị hợp lệ
        if let battery = batteryPercent {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"battery\"\r\n\r\n")
            body.append("\(battery)")
            body.append("\r\n")
        }

        body.append("--\(boundary)--\r\n")

        request.httpBody = body
        return request
    }
}

// MARK: - Error

private enum ImageStreamError: LocalizedError {
    case invalidResponse
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:    return "Phản hồi không hợp lệ từ server."
        case .apiError(let msg):  return msg
        }
    }
}

// MARK: - Data helper

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}
