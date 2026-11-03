import XCTest
import BackpackProtocol
@testable import LEDBackpack

@MainActor
final class SceneTests: XCTestCase {
    private func liveScene(_ name: String = "Commute") -> SavedScene {
        SavedScene(name: name, brightness: 8,
            content: .live(mode: .clock, theme: .standard(for: .clock), message: "HELLO"))
    }

    func testLegacyLibraryWithoutScenesStillLoads() throws {
        let data = Data(#"{"version":1,"media":[],"playlists":[],"preferences":{"mph":true,"fahrenheit":true,"reconnect":true,"backgroundLocation":false,"brakeDisplay":false,"speedCapEnabled":false,"speedCap":60,"disconnectAlerts":true}}"#.utf8)
        let state = try JSONDecoder().decode(LibraryState.self, from: data)
        XCTAssertNil(state.scenes)
        XCTAssertEqual(state.version, 1)
    }

    func testSaveUpdateReloadAndDeleteScene() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = try LocalLibrary(folder: folder)
        var scene = liveScene()
        try library.saveScene(scene)
        scene.name = "Night"; scene.brightness = 2
        try library.saveScene(scene)
        let reloaded = try LocalLibrary(folder: folder)
        XCTAssertEqual(reloaded.state.scenes, [scene])
        try reloaded.deleteScene(scene.id)
        XCTAssertEqual(try LocalLibrary(folder: folder).state.scenes, [])
    }

    func testSceneInputLimitsAndThemeValidation() throws {
        var scene = liveScene(String(repeating: "A", count: 40))
        scene.brightness = 0
        XCTAssertNoThrow(try scene.validate())
        scene.brightness = 15
        XCTAssertNoThrow(try scene.validate())
        scene.brightness = 16
        XCTAssertThrowsError(try scene.validate())
        scene.brightness = -1
        XCTAssertThrowsError(try scene.validate())
        scene = liveScene(String(repeating: "A", count: 41))
        XCTAssertThrowsError(try scene.validate())
        scene.name = "  "
        XCTAssertThrowsError(try scene.validate())
        scene = liveScene()
        var theme = LiveTheme.standard(for: .message)
        scene.content = .live(mode: .message, theme: theme, message: String(repeating: "A", count: 80))
        XCTAssertNoThrow(try scene.validate())
        scene.content = .live(mode: .message, theme: theme, message: "")
        XCTAssertThrowsError(try scene.validate())
        scene.content = .live(mode: .message, theme: theme, message: String(repeating: "A", count: 81))
        XCTAssertThrowsError(try scene.validate())
        theme.background = theme.foreground
        scene.content = .live(mode: .clock, theme: theme, message: "")
        XCTAssertThrowsError(try scene.validate())
    }

    func testPlaylistSceneBindingAndTimingValidation() throws {
        var scene = liveScene()
        scene.content = .playlist(panel: "test-panel", slots: [0, 59], durations: [1, 3600], repeatPlaylist: false)
        XCTAssertNoThrow(try scene.validate())
        scene.content = .playlist(panel: "", slots: [0], durations: nil, repeatPlaylist: true)
        XCTAssertThrowsError(try scene.validate())
        scene.content = .playlist(panel: "test-panel", slots: [], durations: nil, repeatPlaylist: true)
        XCTAssertThrowsError(try scene.validate())
        scene.content = .playlist(panel: "test-panel", slots: [60], durations: nil, repeatPlaylist: true)
        XCTAssertThrowsError(try scene.validate())
        scene.content = .playlist(panel: "test-panel", slots: [0, 1], durations: [1], repeatPlaylist: true)
        XCTAssertThrowsError(try scene.validate())
        scene.content = .playlist(panel: "test-panel", slots: [0], durations: [.nan], repeatPlaylist: true)
        XCTAssertThrowsError(try scene.validate())
        scene.content = .playlist(panel: "test-panel", slots: [0], durations: nil, repeatPlaylist: false)
        XCTAssertThrowsError(try scene.validate())
    }

    func testSceneSnapshotsSurvivePlaylistDeletionAndBackupMerge() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = try LocalLibrary(folder: folder)
        try library.savePlaylist(name: "Showcase", slots: [2, 4], durations: [3, 5])
        let playlist = try XCTUnwrap(library.state.playlists.first)
        let scene = SavedScene(name: "Showcase", brightness: 10,
            content: .playlist(panel: "test-panel", slots: playlist.slots, durations: playlist.durations, repeatPlaylist: true))
        try library.saveScene(scene)
        try library.removePlaylist(playlist.id)
        try library.importBackup(library.backup())
        let scenes = try XCTUnwrap(library.state.scenes)
        XCTAssertEqual(scenes.count, 2)
        XCTAssertNotEqual(scenes[0].id, scenes[1].id)
        XCTAssertEqual(scenes[1].content, scene.content)
        XCTAssertEqual(scenes[1].brightness, 10)
        XCTAssertTrue(library.state.playlists.isEmpty)
    }

    func testSceneLimitAndInvalidBackupLeaveLibraryUnchanged() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = try LocalLibrary(folder: folder)
        for index in 0..<50 { try library.saveScene(liveScene("Scene \(index)")) }
        XCTAssertEqual(library.state.scenes?.count, 50)
        XCTAssertThrowsError(try library.saveScene(liveScene("One too many")))
        var existing = try XCTUnwrap(library.state.scenes?.first)
        existing.brightness = 1
        XCTAssertNoThrow(try library.saveScene(existing))
        XCTAssertThrowsError(try library.importBackup(library.backup()))
        XCTAssertEqual(library.state.scenes?.count, 50)
        var invalid = LibraryState()
        invalid.scenes = [SavedScene(name: "Bad", brightness: 16, content: liveScene().content)]
        let bytes = try JSONEncoder().encode(LibraryBackup(state: invalid, files: [:]))
        XCTAssertThrowsError(try library.importBackup(bytes))
        XCTAssertEqual(library.state.scenes?.count, 50)
    }

    func testInvalidSceneBackupIsRejectedWithoutAnyPlaylists() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = try LocalLibrary(folder: folder)
        var state = LibraryState()
        state.scenes = [SavedScene(name: "Invalid", brightness: 8,
            content: .playlist(panel: "test-panel", slots: [-1], durations: nil, repeatPlaylist: true))]
        let bytes = try JSONEncoder().encode(LibraryBackup(state: state, files: [:]))
        XCTAssertThrowsError(try library.importBackup(bytes))
        XCTAssertNil(library.state.scenes)
        XCTAssertTrue(library.state.media.isEmpty)
    }

    func testInvalidStoredSceneDoesNotResetTheLibraryFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var state = LibraryState()
        var invalid = liveScene()
        invalid.brightness = -1
        state.scenes = [invalid]
        let data = try JSONEncoder().encode(state)
        let file = folder.appendingPathComponent("library.json")
        try data.write(to: file)
        XCTAssertThrowsError(try LocalLibrary(folder: folder))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testSceneKeepsItsOwnLiveThemeSnapshot() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = try LocalLibrary(folder: folder)
        var theme = LiveTheme.standard(for: .clock)
        theme.foreground = .green
        let scene = SavedScene(name: "Night", brightness: 2,
            content: .live(mode: .clock, theme: theme, message: ""))
        try library.saveScene(scene)
        theme.foreground = .magenta
        try library.saveTheme(theme, for: .clock)
        XCTAssertEqual(library.state.scenes?.first, scene)
        XCTAssertEqual(library.theme(for: .clock).foreground, .magenta)
    }
}
