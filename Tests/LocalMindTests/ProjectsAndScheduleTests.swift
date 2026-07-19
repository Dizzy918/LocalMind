//
//  ProjectsAndScheduleTests.swift
//  LocalMindTests
//
//  Tests for projects, pipelines, scheduled runs, and the expanded
//  document importer.
//

import XCTest
@testable import LocalMind

// MARK: - Projects

final class ProjectTests: XCTestCase {

    var dataStore: DataStore!
    var testDir: URL!

    override func setUp() {
        super.setUp()
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMindTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        dataStore = DataStore(baseDirectoryOverride: testDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDir)
        dataStore = nil
        super.tearDown()
    }

    func testProjectSaveAndPersist() {
        let project = Project(name: "Research", emoji: "🔬", systemPrompt: "Be rigorous.")
        dataStore.saveProject(project)
        XCTAssertEqual(dataStore.projects.count, 1)

        let reloaded = DataStore(baseDirectoryOverride: testDir)
        XCTAssertEqual(reloaded.project(withID: project.id)?.name, "Research")
        XCTAssertEqual(reloaded.project(withID: project.id)?.systemPrompt, "Be rigorous.")
    }

    func testDeletingProjectFreesItsConversations() {
        let project = Project(name: "Temp")
        dataStore.saveProject(project)
        var conversation = Conversation(
            title: "In project",
            messages: [ChatMessage(role: .user, content: "hi")],
            projectID: project.id
        )
        dataStore.saveConversation(conversation)

        dataStore.deleteProject(project)

        XCTAssertTrue(dataStore.projects.isEmpty)
        // The conversation survives — just detached from the project.
        conversation = dataStore.conversations.first { $0.id == conversation.id }!
        XCTAssertNil(conversation.projectID)
    }

    func testConversationFilteringByProject() {
        let project = Project(name: "Work")
        dataStore.saveProject(project)

        let loose = Conversation(title: "Loose", messages: [ChatMessage(role: .user, content: "a")])
        let inProject = Conversation(title: "Scoped", messages: [ChatMessage(role: .user, content: "b")], projectID: project.id)
        dataStore.saveConversation(loose)
        dataStore.saveConversation(inProject)

        let chatList = dataStore.conversationsForSelection(.chat)
        XCTAssertTrue(chatList.contains { $0.id == loose.id })
        XCTAssertFalse(chatList.contains { $0.id == inProject.id }, "project chats hide from the loose Chat list")

        let projectList = dataStore.conversationsForSelection(.project(project.id))
        XCTAssertEqual(projectList.map(\.id), [inProject.id])
    }

    func testProjectRoundtrip() throws {
        let project = Project(name: "P", emoji: "📊", agentID: UUID(), knowledgeCollections: ["Docs"])
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded.knowledgeCollections, ["Docs"])
        XCTAssertEqual(decoded.agentID, project.agentID)
    }

    func testLegacyConversationHasNilProject() throws {
        var conversation = Conversation(title: "Old")
        conversation.messages = [ChatMessage(role: .user, content: "hi")]
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(conversation)) as! [String: Any]
        object.removeValue(forKey: "projectID")
        let decoded = try JSONDecoder().decode(
            Conversation.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(decoded.projectID)
    }
}

// MARK: - Pipelines

final class PipelinePersistenceTests: XCTestCase {

    var dataStore: DataStore!
    var testDir: URL!

    override func setUp() {
        super.setUp()
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMindTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        dataStore = DataStore(baseDirectoryOverride: testDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDir)
        dataStore = nil
        super.tearDown()
    }

    func testPipelineSaveDeletePersist() {
        let pipeline = AgentPipeline(name: "Draft & Review", emoji: "✍️", steps: [
            PipelineStep(instruction: "Draft"),
            PipelineStep(instruction: "Critique"),
        ])
        dataStore.savePipeline(pipeline)
        XCTAssertEqual(dataStore.pipelines.count, 1)

        let reloaded = DataStore(baseDirectoryOverride: testDir)
        XCTAssertEqual(reloaded.pipelines.first?.steps.count, 2)

        dataStore.deletePipeline(pipeline)
        XCTAssertTrue(dataStore.pipelines.isEmpty)
    }
}

// MARK: - Scheduled runs

final class ScheduleServiceTests: XCTestCase {

    private var calendar: Calendar { Calendar(identifier: .gregorian) }

    /// A Monday 10:00 reference point for deterministic due-checks.
    private func monday(hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 13 // 2026-07-13 is a Monday
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    func testDueWhenTimePassedAndNotRunToday() {
        let run = ScheduledRun(name: "Morning", prompt: "hi", hour: 9, minute: 0)
        XCTAssertTrue(ScheduleService.isDue(run, now: monday(hour: 9, minute: 30), calendar: calendar))
    }

    func testNotDueBeforeScheduledTime() {
        let run = ScheduledRun(name: "Morning", prompt: "hi", hour: 9, minute: 0)
        XCTAssertFalse(ScheduleService.isDue(run, now: monday(hour: 8, minute: 30), calendar: calendar))
    }

    func testNotDueIfAlreadyRanToday() {
        var run = ScheduledRun(name: "Morning", prompt: "hi", hour: 9, minute: 0)
        run.lastRunDate = monday(hour: 9, minute: 1)
        XCTAssertFalse(ScheduleService.isDue(run, now: monday(hour: 17, minute: 0), calendar: calendar))
    }

    func testDisabledIsNeverDue() {
        var run = ScheduledRun(name: "Off", prompt: "hi", hour: 9, minute: 0, enabled: false)
        XCTAssertFalse(ScheduleService.isDue(run, now: monday(hour: 12, minute: 0), calendar: calendar))
        run.enabled = true
        XCTAssertTrue(ScheduleService.isDue(run, now: monday(hour: 12, minute: 0), calendar: calendar))
    }

    func testWeekdaysFrequencySkipsWeekend() {
        let run = ScheduledRun(name: "Standup", prompt: "hi", hour: 9, minute: 0, frequency: .weekdays)
        // 2026-07-18 is a Saturday, 2026-07-19 a Sunday.
        var saturday = DateComponents(); saturday.year = 2026; saturday.month = 7; saturday.day = 18; saturday.hour = 10
        var sunday = DateComponents(); sunday.year = 2026; sunday.month = 7; sunday.day = 19; sunday.hour = 10
        XCTAssertFalse(ScheduleService.isDue(run, now: calendar.date(from: saturday)!, calendar: calendar))
        XCTAssertFalse(ScheduleService.isDue(run, now: calendar.date(from: sunday)!, calendar: calendar))
        // Monday is fine.
        XCTAssertTrue(ScheduleService.isDue(run, now: monday(hour: 10, minute: 0), calendar: calendar))
    }
}

// MARK: - Document importer markup stripping

final class DocumentImporterTests: XCTestCase {

    func testStripsHTMLTagsAndDecodesEntities() {
        let html = "<p>Hello &amp; welcome</p><p>Line two</p>"
        let text = DocumentImporter.strippingMarkup(html, paragraphBreaks: ["</p>"])
        XCTAssertEqual(text, "Hello & welcome\nLine two")
    }

    func testDropsScriptAndStyleContent() {
        let html = "<style>.a{color:red}</style><p>Visible</p><script>alert(1)</script>"
        let text = DocumentImporter.strippingMarkup(html, paragraphBreaks: ["</p>"])
        XCTAssertEqual(text, "Visible")
        XCTAssertFalse(text?.contains("alert") ?? true)
        XCTAssertFalse(text?.contains("color") ?? true)
    }

    func testEmptyMarkupReturnsNil() {
        XCTAssertNil(DocumentImporter.strippingMarkup("<div></div>", paragraphBreaks: ["</div>"]))
    }

    func testSourceCodeExtensionsAreSupported() {
        for ext in ["swift", "py", "js", "ts", "go", "rs", "yaml"] {
            XCTAssertTrue(DocumentImporter.supportedExtensions.contains(ext), "\(ext) should be importable")
        }
    }

    func testImageExtensionsAreSupportedForOCR() {
        for ext in ["png", "jpg", "jpeg", "heic"] {
            XCTAssertTrue(DocumentImporter.supportedExtensions.contains(ext), "\(ext) should be OCR-importable")
        }
    }
}
