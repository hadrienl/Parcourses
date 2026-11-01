import Testing

@testable import Domain

@Suite struct QuickEntryParserTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let raw: String
    let quantity: String?
    let label: String
    var testDescription: String { raw }
  }

  @Test(arguments: [
    Case(raw: "2 laits demi-écrémé", quantity: "2", label: "laits demi-écrémé"),
    Case(raw: "lait", quantity: nil, label: "lait"),
    Case(raw: "  pain   de  mie ", quantity: nil, label: "pain de mie"),
    Case(raw: "1,5 kg de pommes", quantity: "1,5 kg", label: "pommes"),
    Case(raw: "0.5 L lait", quantity: "0.5 L", label: "lait"),
    Case(raw: "500g farine", quantity: "500g", label: "farine"),
    Case(raw: "2 paquets de pâtes", quantity: "2 paquets", label: "pâtes"),
    Case(raw: "2 boîtes d'ananas", quantity: "2 boîtes", label: "ananas"),
    Case(raw: "3 bouteilles d’eau", quantity: "3 bouteilles", label: "eau"),
    Case(raw: "6x33cl bière", quantity: "6x33cl", label: "bière"),
    Case(raw: "2x lait", quantity: "2x", label: "lait"),
    Case(raw: "2 x lait", quantity: "2", label: "lait"),
    Case(raw: "lait x2", quantity: "2", label: "lait"),
    Case(raw: "2", quantity: nil, label: "2"),
    Case(raw: "1 kg", quantity: nil, label: "1 kg"),
    Case(raw: "x2", quantity: nil, label: "x2"),
    Case(raw: "", quantity: nil, label: ""),
    Case(raw: "   ", quantity: nil, label: ""),
    Case(raw: "1.2.3 truc", quantity: nil, label: "1.2.3 truc"),
    Case(raw: "٣ tomates", quantity: nil, label: "٣ tomates"),
    Case(raw: "de la farine", quantity: nil, label: "de la farine"),
    Case(raw: "2 d'accord", quantity: "2", label: "accord"),
  ])
  func parses(_ c: Case) throws {
    let entry = try QuickEntryParser().parse(c.raw)
    #expect(entry == QuickEntry(quantity: c.quantity, label: c.label))
  }
}
