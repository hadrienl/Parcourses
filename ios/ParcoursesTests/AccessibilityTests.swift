import Foundation
import Testing

@testable import Parcourses

struct ReorderAnnouncementTests {
  private let a = UUID()
  private let b = UUID()
  private let c = UUID()
  private let d = UUID()

  @Test func detectsPermutation() {
    #expect(ReorderAnnouncement.didReorder(previous: [a, b, c], current: [b, a, c]))
  }

  @Test func sameOrderIsNotAReorder() {
    #expect(!ReorderAnnouncement.didReorder(previous: [a, b, c], current: [a, b, c]))
  }

  @Test func additionOrRemovalAloneIsNotAReorder() {
    #expect(!ReorderAnnouncement.didReorder(previous: [a, b, c], current: [a, d, b, c]))
    #expect(!ReorderAnnouncement.didReorder(previous: [a, b, c], current: [a, c]))
  }

  @Test func reorderAlongsideRemovalIsDetected() {
    #expect(ReorderAnnouncement.didReorder(previous: [a, b, c], current: [c, a]))
  }

  @Test func messageNamesTheNextItem() {
    #expect(ReorderAnnouncement.message(next: "lait demi-écrémé") == "Liste réordonnée. Prochain : lait demi-écrémé.")
    #expect(ReorderAnnouncement.message(next: nil) == "Liste réordonnée.")
  }

  @Test func focusStaysOnTheSameRow() {
    #expect(ReorderAnnouncement.focusTarget(previous: [a, b, c], current: [c, b, a], focused: b) == b)
  }

  @Test func focusMovesToTheNeighbourWhenTheRowLeaves() {
    #expect(ReorderAnnouncement.focusTarget(previous: [a, b, c], current: [a, c], focused: b) == c)
    #expect(ReorderAnnouncement.focusTarget(previous: [a, b, c], current: [a, b], focused: c) == b)
    #expect(ReorderAnnouncement.focusTarget(previous: [a], current: [], focused: a) == nil)
  }
}

/// `PrivacyInfo.xcprivacy` doit rester conforme à #9 §15 : pas de suivi, pas de position.
struct PrivacyManifestTests {
  private func manifest(in bundle: Bundle) throws -> [String: Any] {
    let url = try #require(bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
    let data = try Data(contentsOf: url)
    return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
  }

  @Test func appManifestDeclaresNoTrackingAndTheCollectedData() throws {
    let plist = try manifest(in: .main)
    #expect(plist["NSPrivacyTracking"] as? Bool == false)
    #expect((plist["NSPrivacyTrackingDomains"] as? [String]) == [])
    let collected = try #require(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
    let types = Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String })
    #expect(
      types == [
        "NSPrivacyCollectedDataTypeUserID", "NSPrivacyCollectedDataTypeOtherUserContent",
        "NSPrivacyCollectedDataTypeProductInteraction",
      ])
    for entry in collected {
      #expect(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
    }
    // La position n'est jamais conservée : elle n'est pas déclarée.
    #expect(!types.contains { $0.contains("Location") })
  }

  @Test func appManifestDeclaresUserDefaultsReason() throws {
    let plist = try manifest(in: .main)
    let apis = try #require(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
    #expect(apis.count == 1)
    #expect(apis.first?["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults")
    #expect(apis.first?["NSPrivacyAccessedAPITypeReasons"] as? [String] == ["CA92.1"])
  }

  @Test func widgetsExtensionHasItsOwnManifest() throws {
    let url = try #require(Bundle.main.builtInPlugInsURL?.appending(path: "ParcoursesWidgets.appex"))
    let plist = try manifest(in: try #require(Bundle(url: url)))
    #expect(plist["NSPrivacyTracking"] as? Bool == false)
  }

  @Test func attributionPointsToTheOdblNotice() {
    #expect(OpenStreetMap.copyright?.absoluteString == "https://www.openstreetmap.org/copyright")
    #expect(OpenStreetMap.credit.contains("OpenStreetMap"))
  }
}
