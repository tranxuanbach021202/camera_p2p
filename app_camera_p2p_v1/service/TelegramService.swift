//
//  TelegramService.swift
//  app_camera_p2p_v1
//

import Foundation
import Combine
import os

private let telegramLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.camera_p2p", category: "TelegramService")

@MainActor
class TelegramService: ObservableObject {

    var botToken: String
    var chatId: String

    @Published var isSending = false
    @Published var lastError: String?

    init(botToken: String, chatId: String) {
        self.botToken = botToken
        self.chatId = chatId
    }

    // MARK: - Send Photo

    /// Gửi ảnh JPEG lên Telegram bot.
    /// - Parameters:
    ///   - imageData: Dữ liệu JPEG của ảnh.
    ///   - caption: Chú thích kèm theo (tuỳ chọn).
    func sendPhoto(_ imageData: Data, caption: String? = nil) async {
        guard isConfigured else {
            telegramLogger.warning("⚠️ Telegram chưa được cấu hình (botToken hoặc chatId rỗng)")
            return
        }

        guard let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendPhoto") else {
            lastError = "URL Telegram không hợp lệ."
            return
        }

        isSending = true
        lastError = nil
        telegramLogger.debug("📤 Đang gửi ảnh lên Telegram...")

        do {
            let request = buildRequest(url: url, imageData: imageData, caption: caption)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw TelegramError.invalidResponse
            }

            if http.statusCode == 200 {
                telegramLogger.info("✅ Đã gửi ảnh lên Telegram thành công")
            } else {
                // Parse lỗi từ Telegram API (field "description")
                let apiError = parseErrorDescription(from: data) ?? "HTTP \(http.statusCode)"
                throw TelegramError.apiError(apiError)
            }
        } catch {
            let msg = error.localizedDescription
            lastError = "Gửi Telegram thất bại: \(msg)"
            telegramLogger.error("❌ Telegram send error: \(error)")
        }

        isSending = false
    }

    // MARK: - Private Helpers

    var isConfigured: Bool {
        !botToken.isEmpty && botToken != "YOUR_BOT_TOKEN_HERE" &&
        !chatId.isEmpty  && chatId  != "YOUR_CHAT_ID_HERE"
    }

    private func buildRequest(url: URL, imageData: Data, caption: String?) -> URLRequest {
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body = Data()

        // chat_id
        body.appendFormField(name: "chat_id", value: chatId, boundary: boundary)

        // caption (tuỳ chọn)
        if let caption, !caption.isEmpty {
            body.appendFormField(name: "caption", value: caption, boundary: boundary)
        }

        // photo (JPEG binary)
        body.appendFileField(
            name: "photo",
            filename: "photo_\(Int(Date().timeIntervalSince1970)).jpg",
            mimeType: "image/jpeg",
            data: imageData,
            boundary: boundary
        )

        // Closing boundary
        body.append("--\(boundary)--\r\n")

        request.httpBody = body
        return request
    }

    private func parseErrorDescription(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let description = json["description"] as? String else { return nil }
        return description
    }
}

// MARK: - Telegram Error

private enum TelegramError: LocalizedError {
    case invalidResponse
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:     return "Phản hồi không hợp lệ từ server."
        case .apiError(let msg):   return msg
        }
    }
}

// MARK: - Data Multipart Helpers

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }

    /// Thêm một field text vào multipart body.
    mutating func appendFormField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    /// Thêm một field file binary vào multipart body.
    mutating func appendFileField(name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        append(data)
        append("\r\n")
    }
}
