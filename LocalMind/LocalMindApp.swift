//
//  LocalMindApp.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 20.06.26.
//

import SwiftUI

@main
struct LocalMindApp: App {
    @State private var sharedAIManager = AIServiceManager()
    @State private var sharedDataStore = DataStore()
    @AppStorage("isDarkMode") private var isDarkMode: Bool = true
    
    var body: some Scene {
        // By changing this from WindowGroup to Window, macOS knows this is a single-window app.
        // It will now automatically remember your exact window position and size forever!
        Window("LocalMind", id: "main") {
            ContentView(aiManager: sharedAIManager, dataStore: sharedDataStore)
                .frame(minWidth: AppTheme.Dimensions.minWindowWidth, minHeight: AppTheme.Dimensions.minWindowHeight)
                .background(AppTheme.Colors.backgroundPrimary)
                .preferredColorScheme(isDarkMode ? .dark : .light)
                .onAppear {
                    BubbleWindowController.shared.setup(aiManager: sharedAIManager, dataStore: sharedDataStore)
                    
                    HotkeyManager.shared.onHotkeyPressed = {
                        BubbleWindowController.shared.toggle()
                    }
                    HotkeyManager.shared.registerHotkey()
                    HotkeyManager.shared.requestPermissions()
                }
        }
        .commands {
            SidebarCommands()
        }
        
        Settings {
            SettingsView(aiManager: sharedAIManager, dataStore: sharedDataStore)
                .preferredColorScheme(isDarkMode ? .dark : .light)
        }
        
        // Use the label initializer so we can attach a tooltip (.help) to the icon
        MenuBarExtra {
            QuickActionPanel(aiManager: sharedAIManager, dataStore: sharedDataStore)
                .preferredColorScheme(isDarkMode ? .dark : .light)
        } label: {
            Image(systemName: "brain.head.profile")
                .help("LocalMind")
        }
        .menuBarExtraStyle(.window)
    }
}
