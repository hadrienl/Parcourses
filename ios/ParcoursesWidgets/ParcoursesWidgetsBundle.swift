import SwiftUI
import WidgetKit

/// Extension widgets. Accueillera la Live Activity (9.10).
@main
struct ParcoursesWidgetsBundle: WidgetBundle {
  var body: some Widget {
    PlaceholderWidget()
  }
}

/// Widget provisoire pour que l'extension compile.
struct PlaceholderWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "Placeholder", provider: PlaceholderProvider()) { _ in
      Text("Parcourses")
    }
    .configurationDisplayName("Parcourses")
    .supportedFamilies([.systemSmall])
  }
}

struct PlaceholderEntry: TimelineEntry {
  let date: Date
}

struct PlaceholderProvider: TimelineProvider {
  func placeholder(in _: Context) -> PlaceholderEntry { PlaceholderEntry(date: .now) }

  func getSnapshot(in _: Context, completion: @escaping (PlaceholderEntry) -> Void) {
    completion(PlaceholderEntry(date: .now))
  }

  func getTimeline(in _: Context, completion: @escaping (Timeline<PlaceholderEntry>) -> Void) {
    completion(Timeline(entries: [PlaceholderEntry(date: .now)], policy: .never))
  }
}
