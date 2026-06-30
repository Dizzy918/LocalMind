//
//  ProfileSettingsView.swift
//  LocalMind
//
//  Settings tab for the active profile: identity, sign-out, Personal Context
//  editor, and "Import Memory from Another AI" flow.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ProfileSettingsView: View {
    let profileStore: ProfileStore

    @State private var personalContextDraft: String = ""
    @State private var displayNameDraft: String = ""
    @State private var importerOpen = false
    @State private var saveStatus = ""
    @State private var avatarPickError: String = ""

    // Avatar reframing: the raw picked image is held here and the cropper
    // sheet is shown so the user can position/zoom before we save anything.
    // Wrapped because NSImage isn't Identifiable (required by .sheet(item:)).
    @State private var pendingAvatarImage: PickedImage?

    /// Identifiable wrapper so a freshly-picked NSImage can drive
    /// `.sheet(item:)`. A new id per pick guarantees the sheet re-presents
    /// even if the user picks the same file twice.
    struct PickedImage: Identifiable {
        let id = UUID()
        let image: NSImage
    }

    private var profile: UserProfile? { profileStore.currentProfile }

    var body: some View {
        Form {
            if let profile {
                identitySection(profile)
                personalContextSection
                memoryImportSection
                dangerSection
            } else {
                Section { Text("Not signed in.").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .onAppear { hydrate() }
        .onChange(of: profileStore.currentProfileID) { _, _ in hydrate() }
        .sheet(isPresented: $importerOpen) {
            MemoryImporterSheet(profileStore: profileStore) { newContext in
                personalContextDraft = newContext
                profileStore.updateCurrentPersonalContext(newContext)
                saveStatus = "Imported."
            }
        }
        .sheet(item: $pendingAvatarImage) { picked in
            CircularImageCropper(
                image: picked.image,
                onComplete: { data in
                    profileStore.updateCurrentAvatarImageData(data)
                    pendingAvatarImage = nil
                },
                onCancel: { pendingAvatarImage = nil }
            )
        }
    }

    private func hydrate() {
        personalContextDraft = profile?.personalContext ?? ""
        displayNameDraft = profile?.displayName ?? ""
    }

    // MARK: - Sections

    @ViewBuilder
    private func identitySection(_ profile: UserProfile) -> some View {
        // Identity card — avatar with a camera overlay, name + email left-aligned.
        Section {
            HStack(alignment: .center, spacing: AppTheme.Spacing.lg) {
                ZStack(alignment: .bottomTrailing) {
                    AvatarCircle(initials: profile.initials, size: 72, imageData: profile.avatarImageData)

                    Button {
                        pickAvatar()
                    } label: {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(AppTheme.Colors.accentPrimary))
                            .overlay(Circle().stroke(AppTheme.Colors.backgroundSecondary, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .help("Change profile picture")
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayName)
                        .font(.title3).fontWeight(.semibold)
                    if !profile.email.isEmpty {
                        Text(profile.email)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Text(methodLabel(profile.signInMethod))
                        .font(.caption).foregroundStyle(.tertiary)

                    if profile.avatarImageData != nil {
                        Button("Remove photo") {
                            profileStore.updateCurrentAvatarImageData(nil)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .padding(.top, 2)
                    }
                }

                Spacer()
            }
            .padding(.vertical, 4)

            if !avatarPickError.isEmpty {
                Text(avatarPickError)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.statusOffline)
            }
        }

        // Display name — left-aligned value, inline Save that only appears
        // once the field actually differs from the saved name.
        Section("Display name") {
            HStack {
                TextField("Your name", text: $displayNameDraft)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.leading)

                if isDisplayNameDirty {
                    Button("Save") {
                        profileStore.updateCurrentDisplayName(displayNameDraft.trimmingCharacters(in: .whitespaces))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }

    private var isDisplayNameDirty: Bool {
        let trimmed = displayNameDraft.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != (profile?.displayName ?? "")
    }

    /// Opens NSOpenPanel filtered to image types and hands the picked image
    /// to the reframing sheet. Nothing is saved until the user confirms the
    /// crop — so the avatar is never auto-applied straight from disk.
    private func pickAvatar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.title = "Choose a profile picture"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        avatarPickError = ""

        guard let nsImage = NSImage(contentsOf: url) else {
            avatarPickError = "Couldn't read that image."
            return
        }
        pendingAvatarImage = PickedImage(image: nsImage)
    }

    private var personalContextSection: some View {
        Section(
            header: Text("Personal Context"),
            footer: Text("Injected as a system message at the start of every chat in this profile, on every AI backend. Use it for facts about you the AI should always know: your name, role, preferences, communication style, ongoing projects.")
        ) {
            TextEditor(text: $personalContextDraft)
                .frame(minHeight: 160)
                .font(.body)

            HStack {
                Text("\(personalContextDraft.count) chars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !saveStatus.isEmpty {
                    Text(saveStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Button("Save Personal Context") {
                    profileStore.updateCurrentPersonalContext(personalContextDraft)
                    saveStatus = "Saved."
                }
                .disabled(personalContextDraft == (profile?.personalContext ?? ""))
            }
        }
    }

    private var memoryImportSection: some View {
        Section(
            header: Text("Import Memory from Another AI"),
            footer: Text("Most cloud AIs accumulate memory about you over time. LocalMind can't see that directly, but you can ask the other AI to summarise itself into a structured JSON block, paste the reply back here, and we'll merge it into your Personal Context.")
        ) {
            Button {
                importerOpen = true
            } label: {
                Label("Open Memory Importer…", systemImage: "tray.and.arrow.down")
            }
        }
    }

    private var dangerSection: some View {
        Section("Account") {
            Button("Sign Out") {
                profileStore.signOut()
            }
            .foregroundStyle(AppTheme.Colors.statusOffline)
        }
    }

    private func methodLabel(_ method: SignInMethod) -> String {
        switch method {
        case .apple: return "Apple"
        case .google: return "Google (local profile)"
        case .email: return "Email"
        case .guest: return "Guest"
        }
    }
}

// MARK: - Memory Importer Sheet

/// Two-step modal: (1) copy a generated prompt to paste into another AI;
/// (2) paste the AI's JSON reply, parse it, preview, then merge into
/// the active profile's Personal Context.
struct MemoryImporterSheet: View {
    let profileStore: ProfileStore
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var promptCopied = false
    @State private var pastedResponse: String = ""
    @State private var parsedMemory: ImportedMemory?
    @State private var parseError: String = ""
    @State private var mergeMode: MergeMode = .append

    enum MergeMode: String, CaseIterable, Identifiable {
        case replace = "Replace existing context"
        case append  = "Append to existing context"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            HStack {
                Text("Import Memory from Another AI")
                    .font(.title3).fontWeight(.semibold)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    stepOne
                    stepTwo
                    if let parsedMemory {
                        stepThree(parsedMemory)
                    }
                }
                .padding(.bottom, AppTheme.Spacing.lg)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 640, height: 720)
    }

    // MARK: Step 1 — Copy prompt

    private var stepOne: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Label("Step 1 — Copy the prompt", systemImage: "1.circle.fill")
                .font(.headline)
            Text("Open the other AI (ChatGPT, Claude, Gemini, etc.) in a chat where it has memory or context about you. Paste this prompt and send it.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(MemoryImporterSheet.copyPrompt)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppTheme.Spacing.sm)
                    .textSelection(.enabled)
            }
            .frame(height: 160)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusSmall)
                    .fill(AppTheme.Colors.backgroundSecondary)
            )

            HStack {
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(MemoryImporterSheet.copyPrompt, forType: .string)
                    promptCopied = true
                } label: {
                    Label(promptCopied ? "Copied!" : "Copy Prompt", systemImage: promptCopied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
        }
    }

    // MARK: Step 2 — Paste response

    private var stepTwo: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Label("Step 2 — Paste the response", systemImage: "2.circle.fill")
                .font(.headline)
            Text("Paste the JSON block the other AI returned. If it included surrounding text, that's fine — we'll find the JSON.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $pastedResponse)
                .frame(minHeight: 140)
                .font(.system(.caption, design: .monospaced))
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusSmall)
                        .fill(AppTheme.Colors.backgroundSecondary)
                )

            HStack {
                Button("Parse Response") {
                    do {
                        parsedMemory = try ImportedMemory.parse(pastedResponse)
                        parseError = ""
                    } catch {
                        parsedMemory = nil
                        parseError = error.localizedDescription
                    }
                }
                .buttonStyle(.bordered)
                .disabled(pastedResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if !parseError.isEmpty {
                    Text(parseError)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.statusOffline)
                }
                Spacer()
            }
        }
    }

    // MARK: Step 3 — Preview & merge

    private func stepThree(_ memory: ImportedMemory) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Label("Step 3 — Review & save", systemImage: "3.circle.fill")
                .font(.headline)

            Text("Parsed \(memory.facts.count) fact\(memory.facts.count == 1 ? "" : "s") and \(memory.preferences.count) preference\(memory.preferences.count == 1 ? "" : "s").")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(memory.renderForPersonalContext())
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppTheme.Spacing.sm)
                    .textSelection(.enabled)
            }
            .frame(height: 180)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusSmall)
                    .fill(AppTheme.Colors.backgroundSecondary)
            )

            Picker("Merge mode", selection: $mergeMode) {
                ForEach(MergeMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Button("Save to Personal Context") {
                let existing = profileStore.currentProfile?.personalContext ?? ""
                let new = memory.renderForPersonalContext()
                let merged: String
                switch mergeMode {
                case .replace: merged = new
                case .append:
                    if existing.isEmpty { merged = new }
                    else { merged = existing + "\n\n" + new }
                }
                onCommit(merged)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - The prompt the user pastes into another AI

    static let copyPrompt: String = """
    I'm migrating to a new AI assistant called LocalMind. Please summarise everything you've learned about me so the new assistant can pick up where you left off.

    Return ONLY a JSON object that matches this exact schema (no commentary, no markdown fences):

    {
      "name": "string — what to call me",
      "role": "string — what I do for work / why I'm here",
      "facts": ["array of short, stable facts about me"],
      "preferences": ["array of preferences for how I want to be helped"],
      "communication_style": "string — concise notes on tone, length, formality I prefer",
      "ongoing_projects": ["array of current projects or contexts that often come up"],
      "do_not": ["array of things you should avoid doing or topics to handle carefully"]
    }

    If you don't know a field, use an empty string or empty array. Do not invent details. Keep each list item short (one sentence).
    """
}

// MARK: - Importer model

/// The JSON shape the other AI is asked to produce. Parsing is lenient:
/// we extract the first {...} block from the pasted text in case the AI
/// wrapped the JSON in markdown fences or prose.
struct ImportedMemory: Codable {
    var name: String = ""
    var role: String = ""
    var facts: [String] = []
    var preferences: [String] = []
    var communication_style: String = ""
    var ongoing_projects: [String] = []
    var do_not: [String] = []

    enum ParseError: LocalizedError {
        case noJSONFound
        case invalidJSON(String)
        var errorDescription: String? {
            switch self {
            case .noJSONFound: return "Could not find a JSON object in the pasted text."
            case .invalidJSON(let msg): return "Invalid JSON: \(msg)"
            }
        }
    }

    static func parse(_ raw: String) throws -> ImportedMemory {
        // Strip markdown fences if present, then locate the first JSON object.
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}"),
              start < end else {
            throw ParseError.noJSONFound
        }
        let jsonSlice = String(cleaned[start...end])
        guard let data = jsonSlice.data(using: .utf8) else {
            throw ParseError.invalidJSON("encoding")
        }
        do {
            return try JSONDecoder().decode(ImportedMemory.self, from: data)
        } catch {
            throw ParseError.invalidJSON(error.localizedDescription)
        }
    }

    /// Renders the structured memory as a plain-text block suitable for
    /// dropping into Personal Context. We deliberately use plain markdown
    /// rather than JSON because system prompts work better with prose.
    func renderForPersonalContext() -> String {
        var lines: [String] = []
        lines.append("# About me (imported from another AI)")
        if !name.isEmpty { lines.append("- Name: \(name)") }
        if !role.isEmpty { lines.append("- Role: \(role)") }
        if !communication_style.isEmpty {
            lines.append("- Preferred style: \(communication_style)")
        }
        if !facts.isEmpty {
            lines.append("\n## Facts")
            for fact in facts { lines.append("- \(fact)") }
        }
        if !preferences.isEmpty {
            lines.append("\n## Preferences")
            for pref in preferences { lines.append("- \(pref)") }
        }
        if !ongoing_projects.isEmpty {
            lines.append("\n## Ongoing projects")
            for project in ongoing_projects { lines.append("- \(project)") }
        }
        if !do_not.isEmpty {
            lines.append("\n## Do not")
            for item in do_not { lines.append("- \(item)") }
        }
        return lines.joined(separator: "\n")
    }
}
