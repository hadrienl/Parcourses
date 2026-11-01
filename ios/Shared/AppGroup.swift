import Foundation

/// Accès au conteneur partagé entre l'app et ses extensions.
enum AppGroup {
  /// Identifiant lu dans l'Info.plist, renseigné par `APP_GROUP_ID` (xcconfig).
  static var identifier: String {
    guard
      let id = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
      !id.isEmpty
    else {
      preconditionFailure("AppGroupIdentifier absent de l'Info.plist : vérifier APP_GROUP_ID.")
    }
    return id
  }
}
