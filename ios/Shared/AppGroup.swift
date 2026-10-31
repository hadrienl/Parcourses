import Foundation

/// Accès au conteneur partagé entre l'app et ses extensions.
enum AppGroup {
  /// Identifiant lu dans l'Info.plist, renseigné par `APP_GROUP_ID` (xcconfig).
  static var identifier: String {
    Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String ?? "group.app.parcourses"
  }
}
