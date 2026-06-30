//
//  UserProfile.swift
//  LocalMind
//
//  Local-only user profile. LocalMind has no backend, so a "profile" is
//  just a named identity stored on this Mac with its own Personal Context
//  (global instructions the AI sees on every chat, regardless of backend).
//

import Foundation

enum SignInMethod: String, Codable, Sendable {
    case apple    // Real "Sign in with Apple" via AuthenticationServices
    case google   // Local profile labeled as Google (real OAuth needs a backend)
    case email    // Plain local profile with an email address
    case guest    // Anonymous local profile — no auth, no real identity
}

struct UserProfile: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var displayName: String
    var email: String
    var signInMethod: SignInMethod

    /// Stable identifier returned by Sign in with Apple. Lets us recognize the
    /// same Apple ID across reinstalls. Nil for email/google profiles.
    var appleUserID: String?

    /// The global "about me" instructions injected as a system message on
    /// every chat in this profile, regardless of which AI backend is active.
    /// This is the user's portable memory.
    var personalContext: String

    /// Optional avatar bitmap (JPEG, resized to ≤256px on import). Inlined
    /// into the profile JSON because profiles are tiny single-file blobs;
    /// keeping the avatar with the profile means no sidecar bookkeeping.
    var avatarImageData: Data?

    let createdAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        email: String,
        signInMethod: SignInMethod,
        appleUserID: String? = nil,
        personalContext: String = "",
        avatarImageData: Data? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.signInMethod = signInMethod
        self.appleUserID = appleUserID
        self.personalContext = personalContext
        self.avatarImageData = avatarImageData
        self.createdAt = createdAt
    }

    /// First letter of the display name (or "?" if empty) — used by the avatar circle.
    var initials: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }
}
