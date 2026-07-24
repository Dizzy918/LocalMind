//
//  AppServices.swift
//  LocalMind
//
//  A narrow window onto the app's long-lived services for code that runs
//  outside the SwiftUI environment.
//
//  App Intents are instantiated by the system, not by a view, so they can't
//  reach the stores through @Environment the way the rest of the app does.
//  Rather than making every service a singleton, LocalMindApp registers the
//  instances it already owns here at launch, and automation entry points read
//  them back. Nothing else should use this — views get their dependencies
//  injected.
//

import Foundation

@MainActor
enum AppServices {
    private(set) static var dataStore: DataStore?
    private(set) static var aiManager: AIServiceManager?
    private(set) static var generationService: ChatGenerationService?
    private(set) static var profileStore: ProfileStore?

    static func register(
        dataStore: DataStore,
        aiManager: AIServiceManager,
        generationService: ChatGenerationService,
        profileStore: ProfileStore
    ) {
        Self.dataStore = dataStore
        Self.aiManager = aiManager
        Self.generationService = generationService
        Self.profileStore = profileStore
    }

    /// Whether automation entry points can run right now: the app has finished
    /// wiring itself up and someone is signed in (conversations are
    /// profile-scoped, so an ask before sign-in would be orphaned).
    static var isReadyForAutomation: Bool {
        dataStore != nil && generationService != nil && profileStore?.isSignedIn == true
    }
}
