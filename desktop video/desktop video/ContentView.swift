//
//  ContentView.swift
//  desktop video
//
//  Created by 汤子嘉 on 3/20/25.
//

// ContentView.swift (使用 SharedWallpaperWindowManager)

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Foundation

class AppState: ObservableObject {
    static let shared = AppState()

    @Published var lastMediaURL: URL?
    @Published var lastVolume: Float = 1.0
    @Published var lastStretchToFill: Bool = true
}

class ScreenObserver: ObservableObject {
    @Published var screens: [NSScreen] = NSScreen.screens

    private var observer: NSObjectProtocol?
    private var previousScreens: [NSScreen] = NSScreen.screens

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard let self = self else { return }
                let current = NSScreen.screens
                let added = current.filter { !self.previousScreens.contains($0) }
                self.screens = current
                self.previousScreens = current

                if UserDefaults.standard.bool(forKey: "autoSyncNewScreens"), let source = current.first {
                    for screen in added {
                        SharedWallpaperWindowManager.shared.syncWindow(to: screen, from: source)
                    }
                }
            }
        }
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

struct ContentView: View {
    
    @ObservedObject private var appState = AppState.shared
    @AppStorage("isMenuBarOnly") var isMenuBarOnly: Bool = false
    @AppStorage("autoSyncNewScreens") var autoSyncNewScreens: Bool = true
    @State private var syncAllScreens: Bool = false
    @State private var selectedTabScreen: NSScreen? = NSScreen.screens.first
    @StateObject private var screenObserver = ScreenObserver()

    var body: some View {
        VStack {
            Spacer()
            if screenObserver.screens.count > 1 {
                TabView(selection: $selectedTabScreen) {
                    ForEach(screenObserver.screens, id: \.self) { screen in
                        SingleScreenView(screen: screen, syncAllScreens: syncAllScreens, selectedTabScreen: $selectedTabScreen)
                            .id(UUID())
                            .tabItem {
                                Text(screen.localizedNameIfAvailableOrFallback)
                            }
                            .tag(screen)
                    }
                }
            } else if let screen = screenObserver.screens.first {
                SingleScreenView(screen: screen, syncAllScreens: syncAllScreens, selectedTabScreen: $selectedTabScreen)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            
            if screenObserver.screens.count > 1 {
                Button("同步当前屏幕状态到所有屏幕") {
                    if let sourceScreen = selectedTabScreen,
                       let entry = SharedWallpaperWindowManager.shared.screenContent[sourceScreen] {
                        
                        if let fileType = UTType(filenameExtension: entry.url.pathExtension) {
                            if fileType.conforms(to: .movie) || fileType.conforms(to: .image) {
                                SharedWallpaperWindowManager.shared.syncAllWindows(sourceScreen: sourceScreen)
                            } else {
                                for screen in screenObserver.screens {
                                    SharedWallpaperWindowManager.shared.clear(for: screen)
                                }
                            }
                        } else {
                            for screen in screenObserver.screens {
                                SharedWallpaperWindowManager.shared.clear(for: screen)
                            }
                        }
                    } else {
                        for screen in screenObserver.screens {
                            SharedWallpaperWindowManager.shared.clear(for: screen)
                        }
                    }
                }
                .padding()
            }
            
            Toggle("切换 Dock/菜单栏 图标", isOn: Binding(
                get: { !isMenuBarOnly },
                set: { newValue in
                    isMenuBarOnly = !newValue
                    AppDelegate.shared?.setDockIconVisible(newValue)
                }
            ))
            .padding(.bottom)
        }
        .frame(minWidth: 400, idealWidth: 480, maxWidth: .infinity, minHeight: 200, idealHeight: 325, maxHeight: .infinity)
        .padding()
        .frame(maxHeight: .infinity)
    }
}

struct SingleScreenView: View {
    let screen: NSScreen
    let syncAllScreens: Bool
    @Binding var selectedTabScreen: NSScreen?
    @ObservedObject private var appState = AppState.shared
    @State private var dummy: Bool = false  // 用于触发视图刷新
    @State private var volume: Float = 1.0
    @State private var stretchToFill: Bool = true
    @State private var currentEntry: (type: SharedWallpaperWindowManager.ContentType, url: URL, stretch: Bool, volume: Float?)? = nil
    @AppStorage("useMemoryCache") var useMemoryCache: Bool = true

    var body: some View {
        return VStack(spacing: 12) {
            Text("「\(screen.localizedNameIfAvailableOrFallback)」")
                .font(.headline)

            if let entry = currentEntry {
                let filename = (
                    AppState.shared.lastMediaURL?.lastPathComponent.removingPercentEncoding
                    ?? AppState.shared.lastMediaURL?.lastPathComponent
                    ?? entry.url.lastPathComponent.removingPercentEncoding
                    ?? entry.url.lastPathComponent
                )

                Text("正在播放：\(filename)")
                    .font(.subheadline)
                    .foregroundColor(.gray)

                Button("更换视频或图片") {
                    openFilePicker()
                }

                if UTType(filenameExtension: entry.url.pathExtension)?.conforms(to: .movie) == true {
                    Text("音量：\(Int(volume * 100))%")
                    Slider(value: $volume, in: 0...1, step: 0.01)
                        .frame(width: 200)
                        .onChange(of: volume) { newValue in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                let playerVolume = SharedWallpaperWindowManager.shared.players[screen]?.volume ?? newValue
                                if abs(playerVolume - newValue) > 0.01 {
                                    SharedWallpaperWindowManager.shared.updateVideoSettings(
                                        for: screen,
                                        stretch: stretchToFill,
                                        volume: newValue
                                    )
                                    if syncAllScreens {
                                        SharedWallpaperWindowManager.shared.syncAllWindows(sourceScreen: screen)
                                    }
                                }
                            }
                        }
                }

                Toggle("拉伸填充屏幕", isOn: $stretchToFill)
                    .onChange(of: stretchToFill) { newValue in
                        if UTType(filenameExtension: entry.url.pathExtension)?.conforms(to: .movie) == true {
                            SharedWallpaperWindowManager.shared.updateVideoSettings(
                                for: screen,
                                stretch: newValue,
                                volume: volume
                            )
                            if syncAllScreens {
                                SharedWallpaperWindowManager.shared.syncAllWindows(sourceScreen: screen)
                            }
                        } else {
                            SharedWallpaperWindowManager.shared.updateImageStretch(for: screen, stretch: newValue)
                            if syncAllScreens {
                                SharedWallpaperWindowManager.shared.syncAllWindows(sourceScreen: screen)
                            }
                        }
                    }

                Button("关闭壁纸") {
                    SharedWallpaperWindowManager.shared.clear(for: screen)
                    AppState.shared.lastMediaURL = nil
                }
            } else {
                Button("选择视频或图片") {
                    openFilePicker()
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("WallpaperContentDidChange"))) { _ in
            if let entry = SharedWallpaperWindowManager.shared.screenContent[screen] {
                if currentEntry?.url != entry.url ||
                    currentEntry?.volume != entry.volume ||
                    currentEntry?.stretch != entry.stretch {
                    self.currentEntry = entry
                    self.volume = entry.volume ?? 1.0
                    self.stretchToFill = entry.stretch
                    self.dummy.toggle()
                }
            } else {
                self.currentEntry = nil
            }

            if !NSScreen.screens.contains(screen) {
                selectedTabScreen = NSScreen.screens.first
            }
        }
        .onAppear {
            if let entry = SharedWallpaperWindowManager.shared.screenContent[screen] {
                self.currentEntry = entry
                self.volume = entry.volume ?? 1.0
                self.stretchToFill = entry.stretch
                // If lastMediaURL is not set, populate it from entry.url
//                if AppState.shared.lastMediaURL == nil {
//                    AppState.shared.lastMediaURL = entry.url
//                }
            }
        }
    }

    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .image]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            let fileType = UTType(filenameExtension: url.pathExtension)

            if fileType?.conforms(to: .movie) == true {
                appState.lastMediaURL = url
                if useMemoryCache {
                    do {
                        let data = try Data(contentsOf: url)
                        SharedWallpaperWindowManager.shared.showVideoFromMemory(
                            for: screen,
                            data: data,
                            stretch: stretchToFill,
                            volume: volume,
                            originalURL: url
                        )
                    } catch {
                        print("Failed to load video into memory: \(error)")
                    }
                } else {
                    SharedWallpaperWindowManager.shared.showVideo(
                        for: screen,
                        url: url,
                        stretch: stretchToFill,
                        volume: volume
                    )
                }
                if syncAllScreens {
                    SharedWallpaperWindowManager.shared.syncAllWindows(sourceScreen: screen)
                }
            } else if fileType?.conforms(to: .image) == true {
                appState.lastMediaURL = url
                SharedWallpaperWindowManager.shared.showImage(
                    for: screen,
                    url: url,
                    stretch: stretchToFill
                )
                if syncAllScreens {
                    SharedWallpaperWindowManager.shared.syncAllWindows(sourceScreen: screen)
                }
            }
        }
    }
}

fileprivate extension NSScreen {
    var localizedNameIfAvailableOrFallback: String {
        if #available(macOS 14.0, *) {
            return self.localizedName
        } else if let idx = NSScreen.screens.firstIndex(of: self) {
            return "屏幕 \(idx + 1)"
        } else {
            return "未知屏幕"
        }
    }
}
