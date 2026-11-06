import XCTest
@testable import Mirsa

final class MirsaHomeLayoutTests: XCTestCase {
    private func base() -> MirsaHomeLayout { MirsaHomeLayout.fromLegacy(order: ["a", "b", "c", "d"]) }

    func testAppOnAppCreatesFolder() {
        var l = base()
        XCTAssertTrue(l.drop("app:a", onto: "app:b", newFolderID: "f1", newFolderName: "F"))
        XCTAssertEqual(l.items.count, 3)
        XCTAssertEqual(l.folder("f1")?.appIDs, ["b", "a"])
    }

    func testDropOnFolderJoinsAndReorderStillWorks() {
        var l = base()
        l.drop("app:a", onto: "app:b", newFolderID: "f1")
        l.drop("app:c", onto: "folder:f1")
        XCTAssertEqual(l.folder("f1")?.appIDs, ["b", "a", "c"])
        XCTAssertTrue(l.move("app:d", before: "folder:f1"))
        XCTAssertEqual(l.items.first, .app("d"))
    }

    func testRemoveFromFolderDissolvesSingleAndEmpty() {
        var l = base()
        l.drop("app:a", onto: "app:b", newFolderID: "f1")
        l.removeFromFolder("a", folder: "f1")
        XCTAssertNil(l.folder("f1"))
        XCTAssertEqual(Set(l.allAppIDs), ["a", "b", "c", "d"])
        XCTAssertEqual(l.allAppIDs.count, 4)
    }

    func testHiddenMembersSurviveReconcile() {
        var l = base()
        l.drop("app:a", onto: "app:b", newFolderID: "f1")
        l.reconcile(visible: ["b", "c", "d"], all: ["a", "b", "c", "d"])
        XCTAssertEqual(l.folder("f1")?.appIDs, ["b", "a"])
        XCTAssertEqual(l.displayItems(visible: ["b", "c", "d"]).count, 3)
        // Visible-only input without `all` never prunes.
        l.reconcile(visible: ["c"])
        XCTAssertEqual(l.folder("f1")?.appIDs, ["b", "a"])
        // Real deletion with full IDs removes it.
        l.reconcile(visible: ["b", "c", "d"], all: ["b", "c", "d"])
        XCTAssertEqual(Set(l.allAppIDs), ["b", "c", "d"])
    }

    func testNewAppsAppendedAndDuplicatesRemoved() {
        var l = MirsaHomeLayout(items: [.app("a"), .app("a"), .folder(MirsaHomeFolder(id: "f", name: "F", appIDs: ["a", "b", "c"]))])
        l.reconcile(visible: ["a", "b", "c", "n"])
        XCTAssertEqual(l.allAppIDs.filter { $0 == "a" }.count, 1)
        XCTAssertEqual(l.allAppIDs.last, "n")
    }

    func testExcludedDockAppsLeaveGridAndFolders() {
        var l = base()
        l.drop("app:a", onto: "app:b", newFolderID: "f1")
        l.drop("app:c", onto: "folder:f1")
        l.reconcile(visible: ["a", "b", "c", "d"], excluded: ["a"])
        XCTAssertEqual(l.folder("f1")?.appIDs, ["b", "c"])
        XCTAssertFalse(l.allAppIDs.contains("a"))
    }

    func testMigrationAndNamespaceIsolation() async throws {
        let d = UserDefaults(suiteName: "mirsa.home.test.\(UUID().uuidString)")!
        d.set("[\"x\",\"y\"]", forKey: "legacy")
        let main = await MainActor.run { MirsaHomeLayoutStore(namespace: "main", legacyOrderKey: "legacy", defaults: d) }
        let personal = await MainActor.run { MirsaHomeLayoutStore(namespace: "personal", defaults: d) }
        await MainActor.run {
            XCTAssertEqual(main.layout.allAppIDs, ["x", "y"])
            main.mutate { _ = $0.drop("app:x", onto: "app:y", newFolderID: "f") }
            XCTAssertTrue(personal.layout.items.isEmpty)
            let reloaded = MirsaHomeLayoutStore(namespace: "main", defaults: d)
            XCTAssertNotNil(reloaded.layout.folder("f"))
        }
    }

    func testHiddenDockedAppKeptOutOfGridButNotDeleted() {
        var l = base()
        // "d" is hidden and docked: visible list lacks it, all keeps it.
        l.reconcile(visible: ["a", "b", "c"], all: ["a", "b", "c", "d"], excluded: ["d"])
        XCTAssertEqual(l.allAppIDs, ["a", "b", "c"])
        // Unpinned later and visible again: reappears exactly once.
        l.reconcile(visible: ["a", "b", "c", "d"], all: ["a", "b", "c", "d"])
        XCTAssertEqual(l.allAppIDs.filter { $0 == "d" }.count, 1)
    }

    func testHiddenTopLevelPositionPreserved() {
        var l = base()
        l.reconcile(visible: ["a", "c", "d"], all: ["a", "b", "c", "d"])
        XCTAssertEqual(l.allAppIDs, ["a", "b", "c", "d"])
        l.reconcile(visible: ["a", "b", "c", "d"], all: ["a", "b", "c", "d"])
        XCTAssertEqual(l.allAppIDs, ["a", "b", "c", "d"])
    }

    func testFolderOrderInsideFolder() {
        var l = base()
        l.drop("app:a", onto: "app:b", newFolderID: "f1")
        l.drop("app:c", onto: "folder:f1")
        l.moveInFolder("c", folder: "f1", before: "b")
        XCTAssertEqual(l.folder("f1")?.appIDs, ["c", "b", "a"])
    }
}
