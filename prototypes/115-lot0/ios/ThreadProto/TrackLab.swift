import SwiftUI
import UIKit

// Banc de mesure : une `List` dont le trait est dessiné une fois, en fond, d'après les positions publiées par les
// perles. Les scénarios s'enchaînent seuls ; un carré coloré en haut à droite indique la phase en cours, pour que
// `analyze.py` range chaque image de l'enregistrement.

enum Phase: String, CaseIterable {
  case idle, sort, sortBack, departFirst, departLast, check, insert, flingDown, flingUp, flingSlow, done

  /// Couleur du témoin de phase (rouge, vert, bleu sur 0 ou 255, sans ambiguïté après compression).
  var marker: Color {
    let rgb: (Double, Double, Double) =
      switch self {
      case .idle: (0.5, 0.5, 0.5)
      case .sort: (1, 1, 0)
      case .sortBack: (1, 0.5, 0)
      case .departFirst: (0, 1, 0)
      case .departLast: (0, 0.5, 0)
      case .check: (0, 1, 1)
      case .insert: (0.5, 0, 1)
      case .flingDown: (1, 0, 0)
      case .flingUp: (0.5, 0, 0)
      case .flingSlow: (0, 0, 1)
      case .done: (1, 1, 1)
      }
    return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
  }
}

struct TrackLab: View {
  let scenario: String
  /// `spring` : bouts animés avec `Motion.reorder` vers les positions finales (option B telle que conçue).
  /// `none` : bouts posés sans animation. `follow` : départ posé sur l'ancienne position de la ligne qui prend le
  /// rôle, puis ressort calé sur celui d'UIKit (`followResponse`), raccourci du bas retardé après un fondu.
  let trackMode: String
  /// Option A : la liste change sans animation (tri, départ, insertion).
  let listAnimated: Bool
  let followResponse: Double
  @State private var model = TrackModel()
  @State private var items: [Item]
  @State private var phase: Phase = .idle
  @State private var shown: TrackEnds?
  @State private var delayBottom = false

  init(scenario: String, trackMode: String, listAnimated: Bool, followResponse: Double) {
    self.scenario = scenario
    self.trackMode = trackMode
    self.listAnimated = listAnimated
    self.followResponse = followResponse
    let count = scenario == "fling" ? 40 : 12
    _items = State(initialValue: (0..<count).map { Item(id: $0, checked: $0 < 2) })
  }

  var body: some View {
    let roles = ThreadRoles(items)
    List {
      ForEach(items) { item in
        HStack(alignment: .threadMarker, spacing: 0) {
          ThreadGutter(id: item.id, role: roles.role(of: item.id), checked: item.checked, model: model)
          LaneContent(item: item, role: roles.role(of: item.id))
        }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .coordinateSpace(.named(TrackModel.space))
    .animation(listAnimated ? Metrics.reorder : nil, value: items.map(\.id))
    .transaction { if !listAnimated { $0.disablesAnimations = true } }
    .background {
      if let ends = trackMode == "follow" ? shown : TrackEnds.resolve(items: items, model: model) {
        ThreadTrack(ends: ends, probe: true)
          .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(TrackModel.space)).minY } action: {
            model.trackOriginY = $0
          }
          .animation(trackMode == "spring" && model.animated ? Metrics.reorder : nil, value: ends)
      }
    }
    .onChange(of: TrackEnds.resolve(items: items, model: model), initial: true) { _, target in
      // Mode « follow » : les départs ont été posés par `step` avant la mutation ; ici, on anime vers les positions
      // finales avec un ressort calé sur celui des cellules d'UIKit.
      guard trackMode == "follow", let target else { return }
      guard model.animated, shown != nil else {
        shown = target
        return
      }
      let spring = Animation.spring(response: followResponse, dampingFraction: 1)
      if delayBottom, let current = shown {
        // La dernière perle part en fondu : le trait ne se raccourcit qu'après.
        delayBottom = false
        withAnimation(spring) { shown = TrackEnds(top: target.top, junction: target.junction, bottom: current.bottom) }
        withAnimation(spring.delay(0.3)) { shown = target }
      } else {
        withAnimation(spring) { shown = target }
      }
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.listHeight = $0 }
    .background(Color(white: 0.98))
    .overlay(alignment: .topTrailing) {
      // Témoin de phase au coin de l'écran, hors de la zone où défilent les lignes.
      Rectangle().fill(phase.marker).frame(width: 40, height: 40).accessibilityHidden(true)
        .ignoresSafeArea()
    }
    .task { await run() }
  }

  private func step(_ next: Phase, animated: Bool = true, _ change: (inout [Item]) -> Void) async {
    phase = next
    model.animated = animated
    var newItems = items
    change(&newItems)
    if trackMode == "follow", let current = shown {
      // Relevé avant la mutation : nouveaux rôles, positions encore anciennes. Seuls les bouts dont le porteur
      // change repartent de l'ancienne place de leur nouvelle perle ; les autres gardent leur valeur affichée.
      let old = ThreadRoles(items)
      let new = ThreadRoles(newItems)
      if let start = TrackEnds.resolve(items: newItems, model: model) {
        let lastLeaves = old.last.map { id in !newItems.contains { $0.id == id } } ?? false
        delayBottom = lastLeaves
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
          shown = TrackEnds(
            top: new.first == old.first ? current.top : start.top,
            junction: new.next == old.next ? current.junction : start.junction,
            bottom: new.last == old.last || lastLeaves ? current.bottom : start.bottom)
        }
        // Une image entre les deux : sinon la transaction sans animation s'applique aussi à la `List`, qui ne
        // glisse plus (constaté au passage 5, où « follow » mesurait en fait une liste sans animation).
        try? await Task.sleep(for: .milliseconds(20))
      }
    }
    items = newItems
    try? await Task.sleep(for: .seconds(1.6))
    model.animated = false
    try? await Task.sleep(for: .seconds(0.4))
  }

  private func run() async {
    try? await Task.sleep(for: .seconds(3))
    if scenario == "fling" {
      await fling(.flingDown, velocity: 8000)
      await fling(.flingUp, velocity: -8000)
      await fling(.flingSlow, velocity: 2500)
    } else {
      let original = items
      await step(.sort) { order in
        // Le dernier remonte, le prochain descend, un autre devient dernier.
        let last = order.removeLast()
        order.insert(last, at: 4)
        let next = order.remove(at: 2)
        order.insert(next, at: 8)
        let fifth = order.remove(at: 5)
        order.append(fifth)
      }
      await step(.sortBack) { $0 = original }
      await step(.departFirst) { $0.removeFirst() }
      await step(.departLast) { $0.removeLast() }
      await step(.check) { order in
        if let index = order.firstIndex(where: { !$0.checked }) { order[index].checked = true }
      }
      await step(.insert) { order in
        order.insert(Item(id: 100), at: 2)
        order.append(Item(id: 101))
      }
    }
    phase = .done
  }

  /// Lancer : le décalage est piloté image par image avec la décélération normale d'`UIScrollView`, comme un vrai
  /// lancer du doigt (même chemin : `contentOffset` changé dans une boucle d'affichage).
  private func fling(_ next: Phase, velocity: CGFloat) async {
    phase = next
    guard let scrollView = UIApplication.shared.firstScrollView() else { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let driver = FlingDriver(scrollView: scrollView, velocity: velocity) { continuation.resume() }
      driver.start()
    }
    try? await Task.sleep(for: .seconds(1))
  }
}

@MainActor
final class FlingDriver: NSObject {
  private let scrollView: UIScrollView
  private var velocity: CGFloat
  private let completion: () -> Void
  private var link: CADisplayLink?
  private var last: CFTimeInterval = 0
  private var retained: FlingDriver?

  init(scrollView: UIScrollView, velocity: CGFloat, completion: @escaping () -> Void) {
    self.scrollView = scrollView
    self.velocity = velocity
    self.completion = completion
  }

  func start() {
    retained = self
    let link = CADisplayLink(target: self, selector: #selector(tick))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  @objc private func tick(_ link: CADisplayLink) {
    if last == 0 {
      last = link.timestamp
      return
    }
    let dt = link.timestamp - last
    last = link.timestamp
    velocity *= pow(UIScrollView.DecelerationRate.normal.rawValue, CGFloat(dt * 1000))
    let minY = -scrollView.adjustedContentInset.top
    let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
    var y = scrollView.contentOffset.y + velocity * CGFloat(dt)
    if y <= minY || y >= maxY {
      y = min(max(y, minY), maxY)
      velocity = 0
    }
    scrollView.contentOffset.y = y
    if abs(velocity) < 20 {
      link.invalidate()
      self.link = nil
      completion()
      retained = nil
    }
  }
}

extension UIApplication {
  /// `UICollectionView` sous la `List` (la première `UIScrollView` trouvée n'est pas la bonne).
  func firstScrollView() -> UIScrollView? {
    let window = connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    func find(_ view: UIView) -> UIScrollView? {
      if let scroll = view as? UICollectionView { return scroll }
      for sub in view.subviews { if let found = find(sub) { return found } }
      return nil
    }
    return window.flatMap(find)
  }
}
