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

  /// Changement d'identifiants (perte de session, `apply(_ remap:)`) : aucune annonce, même ordre.
  @Test func identifierRemapIsNotAReorder() {
    #expect(!ReorderAnnouncement.didReorder(previous: [a, b, c], current: [UUID(), UUID(), UUID()]))
    #expect(!ReorderAnnouncement.didReorder(previous: [a, b, c], current: [d, b, c]))
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
        "NSPrivacyCollectedDataTypeProductInteraction", "NSPrivacyCollectedDataTypePurchaseHistory",
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
    let userDefaults = apis.first {
      $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults"
    }
    #expect(userDefaults?["NSPrivacyAccessedAPITypeReasons"] as? [String] == ["CA92.1"])
  }

  /// Toute API à raison obligatoire présente dans le code doit être déclarée dans le manifeste de sa cible, avec
  /// au moins une raison. Les sources sont lues depuis le dépôt (le simulateur voit le disque de l'hôte).
  @Test(arguments: [
    (["Parcourses", "Shared", "Packages/Domain/Sources", "Packages/SortEngine/Sources"], "Parcourses"),
    (["ParcoursesWidgets", "Shared"], "ParcoursesWidgets"),
  ])
  func requiredReasonAPIsInCodeAreDeclared(sources: [String], target: String) throws {
    let ios = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let found = try RequiredReasonAPI.categories(in: sources.map { ios.appending(path: $0) })
    let url = ios.appending(path: "\(target)/PrivacyInfo.xcprivacy")
    let data = try Data(contentsOf: url)
    let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    let apis = plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []
    var declared: Set<String> = []
    for api in apis {
      guard let type = api["NSPrivacyAccessedAPIType"] as? String else { continue }
      #expect(!(api["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []).isEmpty, "\(type) sans raison")
      declared.insert(type)
    }
    let missing = found.filter { !declared.contains($0.key) }
    #expect(missing.isEmpty, "API à raison obligatoire non déclarées dans \(target) : \(missing)")
  }

  @Test func detectorFindsKnownPatterns() {
    let found = RequiredReasonAPI.categories(inSource: "let t = ProcessInfo.processInfo.systemUptime\n// UserDefaults")
    #expect(Set(found) == ["NSPrivacyAccessedAPICategorySystemBootTime"])
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

/// Détecteur d'API à raison obligatoire (liste Apple : horodatages de fichiers, démarrage du système, espace disque,
/// claviers actifs, `UserDefaults`). Les lignes de commentaire sont ignorées.
enum RequiredReasonAPI {
  static let patterns: [String: [String]] = [
    "NSPrivacyAccessedAPICategoryFileTimestamp": [
      "creationDate", "modificationDate", "contentModificationDate", "fileModificationDate", "creationDateKey",
      "getattrlist", "fstat(", "lstat(", ".stat(",
    ],
    "NSPrivacyAccessedAPICategorySystemBootTime": ["systemUptime", "mach_absolute_time"],
    "NSPrivacyAccessedAPICategoryDiskSpace": [
      "volumeAvailableCapacity", "volumeTotalCapacity", "systemFreeSize", "systemSize", "statfs", "statvfs",
    ],
    "NSPrivacyAccessedAPICategoryActiveKeyboards": ["activeInputModes"],
    "NSPrivacyAccessedAPICategoryUserDefaults": ["UserDefaults", "@AppStorage"],
  ]

  static func categories(inSource source: String) -> [String] {
    let code = source.split(separator: "\n")
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
      .joined(separator: "\n")
    return patterns.filter { _, needles in needles.contains { code.contains($0) } }.map(\.key)
  }

  /// Catégorie → fichiers où elle apparaît.
  static func categories(in directories: [URL]) throws -> [String: [String]] {
    var result: [String: [String]] = [:]
    for directory in directories {
      let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
      #expect(files != nil, "sources introuvables : \(directory.path)")
      while let file = files?.nextObject() as? URL {
        guard file.pathExtension == "swift" else { continue }
        for category in categories(inSource: try String(contentsOf: file, encoding: .utf8)) {
          result[category, default: []].append(file.lastPathComponent)
        }
      }
    }
    return result
  }
}
