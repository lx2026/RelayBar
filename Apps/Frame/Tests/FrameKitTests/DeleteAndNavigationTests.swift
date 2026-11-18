import BridgeProtocol
import AppKit
import SwiftData
import XCTest
@testable import FrameKit

final class DeleteAndNavigationTests: XCTestCase {
  func testFavoriteShortcutWorksInGridAndViewerWithoutInterceptingText() {
    for viewing in [false, true] {
      XCTAssertEqual(MediaKeyAction.resolve(keyCode: 3, modifiers: [], viewing: viewing, editingText: false), .favorite)
      XCTAssertNil(MediaKeyAction.resolve(keyCode: 3, modifiers: [], viewing: viewing, editingText: true))
      XCTAssertNil(MediaKeyAction.resolve(keyCode: 3, modifiers: .command, viewing: viewing, editingText: false))
    }
  }
  func testKeysMeantForATextControlThatLostTheFocusAreSwallowed() {
    var typing = TypingGuard()
    XCTAssertEqual(typing.key(code: 0, focused: .search, wouldAct: false), .pass)
    // The field lost the focus on its own: Backspace, F and Space were still meant for it.
    for key: UInt16 in [51, 3, 49] {
      XCTAssertEqual(typing.key(code: key, focused: nil, wouldAct: true), .swallow(refocusSearch: true))
    }
    XCTAssertEqual(typing.key(code: 12, focused: nil, wouldAct: false), .pass, "A key that runs no shortcut is left alone")
    XCTAssertEqual(typing.key(code: 51, focused: nil, wouldAct: true), .swallow(refocusSearch: true), "and does not release the guard")
    typing.pointerDown()
    XCTAssertEqual(typing.key(code: 51, focused: nil, wouldAct: true), .pass, "A click chose where the focus went")

    // Editing commands (the A of Command-A, the V of Command-V) and Return, Enter or Escape in the search
    // field keep the guard on, because the field keeps the focus.
    for key: UInt16 in [0, 9, 36, 76, 53] {
      XCTAssertEqual(typing.key(code: key, focused: .search, wouldAct: false), .pass)
      XCTAssertEqual(typing.key(code: 51, focused: nil, wouldAct: true), .swallow(refocusSearch: true), "after key \(key)")
    }

    // Tab leaves a field on purpose.
    XCTAssertEqual(typing.key(code: 0, focused: .search, wouldAct: false), .pass)
    XCTAssertEqual(typing.key(code: 48, focused: .search, wouldAct: false), .pass)
    XCTAssertEqual(typing.key(code: 51, focused: nil, wouldAct: true), .pass)

    // In any other field, Return, Enter and Escape end the editing too.
    XCTAssertEqual(typing.key(code: 0, focused: .other, wouldAct: false), .pass)
    XCTAssertEqual(typing.key(code: 3, focused: nil, wouldAct: true), .swallow(refocusSearch: false))
    for key: UInt16 in [36, 76, 53] {
      XCTAssertEqual(typing.key(code: 0, focused: .other, wouldAct: false), .pass)
      XCTAssertEqual(typing.key(code: key, focused: .other, wouldAct: false), .pass)
      XCTAssertEqual(typing.key(code: 51, focused: nil, wouldAct: true), .pass, "after key \(key)")
    }

    var fresh = TypingGuard()
    for key: UInt16 in [51, 3, 49] {
      XCTAssertEqual(fresh.key(code: key, focused: nil, wouldAct: true), .pass, "Without earlier typing nothing changes")
    }
    // Command-Backspace deletes the selection too, so it is one of the keys the guard covers.
    XCTAssertEqual(MediaKeyAction.resolve(keyCode: 51, modifiers: .command, viewing: false, editingText: false), .delete)
  }
  @MainActor func testTextControlsBeingEditedAreRecognized() {
    let search = EditedSearchField()
    search.identifier = TypingGuard.searchFieldIdentifier
    let editor = NSTextView()
    editor.isFieldEditor = true
    editor.delegate = search
    XCTAssertEqual(TypingGuard.field(for: editor), .search, "A field editor stands for the field it edits")
    XCTAssertEqual(TypingGuard.field(for: search), .search)
    XCTAssertEqual(TypingGuard.field(for: NSTextField()), .other)
    let notes = NSTextView()
    XCTAssertEqual(TypingGuard.field(for: notes), .other)
    notes.isEditable = false
    XCTAssertNil(TypingGuard.field(for: notes))
    XCTAssertFalse(TypingGuard.isEditingText(notes))
    XCTAssertFalse(TypingGuard.isEditingText(NSView()))
    XCTAssertNil(TypingGuard.field(for: nil))
  }
  func testDeleteAndViewerArrowsIgnoreHardwareFlagsButNotTextEditing() {
    for key: UInt16 in [51, 117] {
      for viewing in [false, true] {
        XCTAssertEqual(MediaKeyAction.resolve(keyCode: key, modifiers: [], viewing: viewing, editingText: false), .delete)
        XCTAssertEqual(MediaKeyAction.resolve(keyCode: key, modifiers: .command, viewing: viewing, editingText: false), .delete)
        XCTAssertNil(MediaKeyAction.resolve(keyCode: key, modifiers: [], viewing: viewing, editingText: true))
        XCTAssertNil(MediaKeyAction.resolve(keyCode: key, modifiers: .option, viewing: viewing, editingText: false))
      }
    }
    for (key, action): (UInt16, MediaKeyAction) in [(123, .previous), (124, .next)] {
      XCTAssertEqual(MediaKeyAction.resolve(keyCode: key, modifiers: [.numericPad, .function], viewing: true, editingText: false), action)
      XCTAssertNil(MediaKeyAction.resolve(keyCode: key, modifiers: [], viewing: false, editingText: false))
      XCTAssertNil(MediaKeyAction.resolve(keyCode: key, modifiers: [], viewing: true, editingText: true))
      XCTAssertNil(MediaKeyAction.resolve(keyCode: key, modifiers: .shift, viewing: true, editingText: false))
    }
  }

  @MainActor private func withRemoteStore(_ body: (LibraryStore, MutationFixture) async throws -> Void) async throws {
    let fixture = MutationFixture()
    let client = RelayRemoteClient(transport: { await fixture.list($0) })
    let container = try ModelContainer(for: LibraryRootRecord.self, FavoriteRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let actions = FixtureRemoteActions(mutation: { try await fixture.mutate($0, action: $1, root: $2); return nil },
                                      deletion: { await fixture.delete($0, root: $1) })
    let store = makeRemoteStore(defaults: UserDefaults(suiteName: "FrameDelete.\(UUID())")!,
      remoteFolderLoader: { try await client.list(source: $0, path: $1) },
      remoteOpenRecorder: { _, _ in XCTFail("Frame must not write RelayBar history") }, actions: actions)
    addTeardownBlock { await store.shutdown(); await client.shutdown() }
    await store.start(modelContext: container.mainContext)
    await store.openRemote(fixture.source, path: "/photos")
    store.setFileTypeFilter(.images)
    store.setViewMode(.contactSheet)
    try await body(store, fixture)
  }

  @MainActor func testDeleteButtonImmediatelyDeletesBatchAndPairWithoutUndo() async throws {
    try await withRemoteStore { store, fixture in
      let photos = store.visiblePhotos
      store.updateGridSelection(Set(photos.prefix(2).map(\.id)), currentID: photos[0].id)
      XCTAssertEqual(store.selectedMemberCount, 3)
      XCTAssertEqual(store.deleteTitle, "Delete")
      store.deleteSelected()
      for _ in 0..<200 {
        if await fixture.actions.count == 2, !store.isFileOperation, !store.isScanning { break }
        try await Task.sleep(for: .milliseconds(5))
      }
      let actions = await fixture.actions, files = await fixture.files
      XCTAssertEqual(actions, ["delete:a.jpg", "delete:b.jpg"])
      XCTAssertEqual(files, ["c.jpg"])
      XCTAssertEqual(store.visiblePhotos.map(\.name), ["c.jpg"])
      store.clearFileFilters()
      XCTAssertEqual(store.visiblePhotos.map(\.name), ["c.jpg"], "Deleting a group also removes its visible companion row")
      XCTAssertFalse(store.canUndoTrash)
      XCTAssertNil(store.notice?.actionTitle)
      XCTAssertEqual(store.notice?.message, "2 deleted")
      XCTAssertTrue(store.fileActionFailures.isEmpty)
      XCTAssertEqual(store.availableFilters, [.all, .favorites, .notFavorited, .archive])
      let calls = await fixture.deleteCalls, lists = await fixture.listCalls
      XCTAssertEqual(calls, 1)
      XCTAssertEqual(lists, 1, "Deletion must not reopen or rescan the folder")
    }
  }

  @MainActor func testFullSizeArrowsNavigateFolderRatherThanOnlyBatchAndDeleteAdvances() async throws {
    try await withRemoteStore { store, fixture in
      let photos = store.visiblePhotos
      store.updateGridSelection([photos[0].id, photos[1].id], currentID: photos[1].id)
      store.openViewer()
      store.navigate(by: 1)
      XCTAssertEqual(store.selectedPhoto?.name, "c.jpg")
      store.navigate(by: 1)
      XCTAssertEqual(store.selectedPhoto?.name, "a.jpg")
      store.navigate(by: -1)
      XCTAssertEqual(store.selectedPhoto?.name, "c.jpg")
      store.navigate(by: -1)
      XCTAssertEqual(store.selectedPhoto?.name, "b.jpg")
      await store.deleteSelection()
      XCTAssertEqual(store.selectedPhoto?.name, "c.jpg")
      XCTAssertEqual(store.viewMode, .inspect)
      XCTAssertEqual(store.viewMode, .inspect)
      let actions = await fixture.actions
      XCTAssertEqual(actions, ["delete:b.jpg"])
      store.navigate(by: -1)
      XCTAssertEqual(store.selectedPhoto?.name, "a.jpg")
    }
  }

  @MainActor func testFailedDeleteStaysVisibleAndDoesNotOfferUndo() async throws {
    try await withRemoteStore { store, fixture in
      await fixture.failNextDelete()
      await store.deleteSelection()
      XCTAssertEqual(store.visiblePhotos.count, 3)
      XCTAssertEqual(store.fileActionFailures.count, 1)
      XCTAssertEqual(store.fileActionFailures.first?.reason, "Permission denied")
      XCTAssertFalse(store.canUndoTrash)
      XCTAssertNil(store.notice?.actionTitle)
    }
  }

  @MainActor func testDiscontiguousDeleteKeepsSurvivingPreviewAndCheckedSet() async throws {
    try await withRemoteStore { store, _ in
      let photos = store.visiblePhotos
      store.toggleSelectMode()
      store.toggleCurrentSelection() // a
      store.navigate(by: 1)
      XCTAssertEqual(store.batchSelection.ids, [photos[0].id])
      store.navigate(by: 1)
      store.toggleCurrentSelection() // c
      store.navigate(by: -1) // preview b; delete a and c
      XCTAssertEqual(store.selectedPhoto?.name, "b.jpg")
      XCTAssertEqual(store.actionPhotos.map(\.name), ["a.jpg", "c.jpg"])
      await store.deleteSelection()
      XCTAssertEqual(store.selectedPhoto?.name, "b.jpg")
      XCTAssertEqual(store.visiblePhotos.map(\.name), ["b.jpg"])
      XCTAssertTrue(store.batchSelection.ids.isEmpty)
      XCTAssertFalse(store.canDelete)
      XCTAssertTrue(store.canInspect)
      store.toggleCurrentSelection()
      store.inspect(photos[1])
      XCTAssertEqual(store.actionPhotos.count, 1)
    }
  }

  func testNextPreviewUsesPreviousVisibleOrderNotNewIndex() {
    let order = ["a", "b", "c", "d", "e"]
    XCTAssertEqual(MediaSelection.nextPreview(in: order, current: "c", removing: ["a", "c"]), "d")
    XCTAssertEqual(MediaSelection.nextPreview(in: order, current: "c", removing: ["a", "e"]), "c")
    XCTAssertEqual(MediaSelection.nextPreview(in: order, current: "e", removing: ["a", "e"]), "d")
    XCTAssertNil(MediaSelection.nextPreview(in: order, current: "e", removing: Set(order)))
  }
}

private actor MutationFixture {
  let source = BridgeSource(id: String(repeating: "b", count: 64), name: "Delete test")
  var files = ["a.jpg", "a.jpg.json", "b.jpg", "c.jpg"]
  var actions: [String] = []
  var fails = false
  var deleteCalls = 0
  var listCalls = 0
  func failNextDelete() { fails = true }
  func list(_ request: BridgeRequest) -> BridgeResponse {
    var response = BridgeResponse()
    if request.operation == "list" {
      listCalls += 1
      response.listingID = UUID()
      response.entries = files.map { BridgeEntry(name: $0, path: "/photos/" + $0, directory: false, size: 12, modified: "fixture") }
    }
    return response
  }
  func delete(_ photos: [PhotoItem], root: String) -> [FileActionFailure] {
    deleteCalls += 1
    return photos.compactMap { photo in
      do { try mutate(photo, action: "delete", root: root); return nil }
      catch { return FileActionFailure(photo: photo, reason: error.localizedDescription) }
    }
  }
  func mutate(_ photo: PhotoItem, action: String, root: String) throws {
    XCTAssertEqual(action, "delete")
    XCTAssertEqual(root, "/photos")
    if fails { throw BridgeError("Permission denied") }
    actions.append(action + ":" + photo.name)
    files.removeAll { $0 == photo.name || $0 == photo.remote?.sidecar?.name }
  }
}

/// A search field that AppKit would make its field editor's delegate; Swift needs the conformance spelled out.
private final class EditedSearchField: NSSearchField, NSTextViewDelegate {}
