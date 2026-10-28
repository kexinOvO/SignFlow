import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String?, String?) -> Void)?
    private var delivered: [String: Date] = [:]
    private(set) var lastError: String?
    func configure() { UNUserNotificationCenter.current().delegate = self }
    func requestAuthorization() async throws -> Bool { try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
    func status() async -> UNAuthorizationStatus { await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
    func send(key: String, title: String, body: String, projectID: UUID? = nil, taskID: UUID? = nil) async {
        guard delivered[key].map({ Date().timeIntervalSince($0) < 6 * 3600 }) != true else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
        content.userInfo = ["projectID": projectID?.uuidString ?? "", "taskID": taskID?.uuidString ?? ""]
        do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil)); delivered[key] = Date(); lastError = nil }
        catch { lastError = "系统通知发送失败：" + error.localizedDescription }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let project = response.notification.request.content.userInfo["projectID"] as? String
        let task = response.notification.request.content.userInfo["taskID"] as? String
        await MainActor.run { onOpen?(project, task) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}
