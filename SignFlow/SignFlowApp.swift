//
//  SignFlowApp.swift
//  SignFlow
//
//  Created by 可可可心 on 10/26/26.
//

import SwiftUI
import AppKit

@main
struct SignFlowApp: App {
    @NSApplicationDelegateAdaptor(SignFlowDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("SignFlow", id: "main") {
            RootView().environmentObject(model).preferredColorScheme(model.appearance)
                .task { delegate.model = model; await model.start() }
                .onChange(of: model.state.settings) { _, _ in model.save() }
        }
        .defaultSize(width: 1220, height: 820)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) { Button("添加 Xcode 项目…", action: model.addProject).keyboardShortcut("o") }
            CommandMenu("操作") {
                Button("检查全部项目", action: model.checkAll).keyboardShortcut("r")
                Button("执行到期续签") { model.renewDue() }
                Divider()
                Button(model.state.settings.automationPaused ? "恢复自动续签" : "暂停自动续签") { model.updateSettings { $0.automationPaused.toggle() } }
            }
        }
        Settings { SettingsView().environmentObject(model).preferredColorScheme(model.appearance).frame(width: 720, height: 740) }
        MenuBarExtra("SignFlow", systemImage: model.runningTasks.isEmpty ? "checkmark.shield" : "arrow.triangle.2.circlepath", isInserted: Binding(get: { model.state.settings.showMenuBar }, set: { value in model.menuBarVisibilityChanged(value) })) {
            MenuBarView().environmentObject(model)
        }.menuBarExtraStyle(.window)
    }
}

@MainActor
final class SignFlowDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminationTask: Task<Void, Never>?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !(model?.state.settings.keepRunning ?? true) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if terminationTask == nil {
            model.stop()
            terminationTask = Task { @MainActor in
                await model.shutdown()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { model?.stop() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { model?.openMainWindow(); return true }
}
