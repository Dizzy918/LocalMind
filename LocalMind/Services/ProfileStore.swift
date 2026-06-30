//
//  ProfileStore.swift
//  LocalMind
//
//  Manages user profiles on this Mac. Profiles are JSON files under
//  ~/Library/Application Support/LocalMind/profiles/, plus a UserDefaults
//  pointer for the active profile so it survives relaunch.
//
//  Profiles partition Personal Context (and only Personal Context, for v1):
//  switching profile swaps the global instructions injected into every chat.
//  Conversations themselves stay shared across profiles to keep migration
//  painless for existing users.
//

import Foundation
import SwiftUI

@Observable
@MainActor
final class ProfileStore {
    private(set) var profiles: [UserProfile] = []
    private(set) var currentProfileID: UUID?

    /// Fires once, when the user creates their very first profile. The app
    /// wires this to DataStore.claimOrphanConversations so pre-existing
    /// chats get assigned to the first user instead of vanishing.
    var onFirstProfileCreated: ((UUID) -> Void)?

    private let fileManager = FileManager.default
    private let baseDirectory: URL
    private let activeProfileKey = "activeProfileID"

    init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        baseDirectory = appSupport
            .appendingPathComponent("LocalMind", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        loadAll()

        if let raw = UserDefaults.standard.string(forKey: activeProfileKey),
           let id = UUID(uuidString: raw),
           profiles.contains(where: { $0.id == id }) {
            currentProfileID = id
        }
    }

    // MARK: - Computed

    var currentProfile: UserProfile? {
        guard let id = currentProfileID else { return nil }
        return profiles.first { $0.id == id }
    }

    var isSignedIn: Bool { currentProfile != nil }

    // MARK: - Persistence

    private func profileURL(for id: UUID) -> URL {
        baseDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func loadAll() {
        guard let files = try? fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [UserProfile] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let profile = try? decoder.decode(UserProfile.self, from: data) {
                loaded.append(profile)
            }
        }
        profiles = loaded.sorted { $0.createdAt < $1.createdAt }
    }

    private func save(_ profile: UserProfile) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(profile) {
            try? data.write(to: profileURL(for: profile.id), options: .atomic)
        }
    }

    // MARK: - Mutations

    /// Creates a new profile, persists it, and sets it as active.
    @discardableResult
    func createProfile(displayName: String, email: String, method: SignInMethod, appleUserID: String? = nil) -> UserProfile {
        // If an Apple profile already exists for this Apple user ID, reuse it.
        if method == .apple, let appleID = appleUserID,
           let existing = profiles.first(where: { $0.appleUserID == appleID }) {
            selectProfile(existing.id)
            return existing
        }
        // For email/google, dedupe by email (case-insensitive) so re-signing in
        // returns the same profile instead of stacking duplicates. Guests skip
        // dedup — every "Continue as Guest" creates a fresh profile.
        if method != .apple && method != .guest,
           let existing = profiles.first(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame && $0.signInMethod == method }) {
            selectProfile(existing.id)
            return existing
        }

        let isFirstProfile = profiles.isEmpty
        let profile = UserProfile(
            displayName: displayName,
            email: email,
            signInMethod: method,
            appleUserID: appleUserID
        )
        profiles.append(profile)
        save(profile)
        selectProfile(profile.id)
        if isFirstProfile {
            onFirstProfileCreated?(profile.id)
        }
        return profile
    }

    func selectProfile(_ id: UUID) {
        currentProfileID = id
        UserDefaults.standard.set(id.uuidString, forKey: activeProfileKey)
    }

    func updateCurrentPersonalContext(_ text: String) {
        guard let id = currentProfileID,
              let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].personalContext = text
        save(profiles[idx])
    }

    func updateCurrentDisplayName(_ name: String) {
        guard let id = currentProfileID,
              let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].displayName = name
        save(profiles[idx])
    }

    /// Sets (or clears, via nil) the active profile's avatar image data.
    /// Persists immediately. The caller is responsible for resizing /
    /// compressing the image before passing it in — see
    /// `ProfileSettingsView.optimizeAvatar(_:)`.
    func updateCurrentAvatarImageData(_ data: Data?) {
        guard let id = currentProfileID,
              let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].avatarImageData = data
        save(profiles[idx])
    }

    func signOut() {
        currentProfileID = nil
        UserDefaults.standard.removeObject(forKey: activeProfileKey)
    }

    func deleteProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        try? fileManager.removeItem(at: profileURL(for: id))
        if currentProfileID == id { signOut() }
    }

    // MARK: - Static accessor for non-View code paths
    //
    // ChatView (and friends) build the system prompt on a non-main task and
    // we don't want to thread ProfileStore through every call site. This
    // helper reads the active profile's Personal Context directly from disk.
    // Cheap: one small JSON read per chat send.

    static func currentPersonalContext() -> String {
        let key = "activeProfileID"
        guard let raw = UserDefaults.standard.string(forKey: key),
              let uuid = UUID(uuidString: raw) else { return "" }
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = appSupport
            .appendingPathComponent("LocalMind/profiles/\(uuid.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return "" }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let profile = try? decoder.decode(UserProfile.self, from: data) else {
            return ""
        }
        return profile.personalContext
    }
}
