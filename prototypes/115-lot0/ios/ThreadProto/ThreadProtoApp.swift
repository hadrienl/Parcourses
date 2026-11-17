import SwiftUI

// Arguments : `-scenario sort|fling|lane`, `-trackAnim spring|none|follow`, `-trackResponse 0.3`,
// `-listAnim none` (option A), `-rtl 1`.
@main
struct ThreadProtoApp: App {
  private let defaults = UserDefaults.standard

  var body: some Scene {
    WindowGroup {
      root
        .environment(\.layoutDirection, defaults.bool(forKey: "rtl") ? .rightToLeft : .leftToRight)
        .preferredColorScheme(.light)
        .statusBarHidden()
    }
  }

  @ViewBuilder private var root: some View {
    let scenario = defaults.string(forKey: "scenario") ?? "sort"
    if scenario == "lane" {
      LaneRoot()
    } else {
      TrackLab(
        scenario: scenario,
        trackMode: defaults.string(forKey: "trackAnim") ?? "spring",
        listAnimated: defaults.string(forKey: "listAnim") != "none",
        followResponse: defaults.object(forKey: "trackResponse") == nil ? 0.3 : defaults.double(forKey: "trackResponse"))
    }
  }
}

/// Pile de navigation ouverte sur le banc des gestes : le geste retour du bord d'écran existe.
struct LaneRoot: View {
  @State private var path: [Int] = [1]

  var body: some View {
    NavigationStack(path: $path) {
      List {
        NavigationLink("Ouvrir le couloir", value: 1)
      }
      .navigationTitle("Racine")
      .accessibilityIdentifier("root")
      .navigationDestination(for: Int.self) { _ in LaneLab() }
    }
  }
}
