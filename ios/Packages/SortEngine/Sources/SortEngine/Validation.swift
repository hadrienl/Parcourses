// Validation des entrées, dans le même ordre que `validate` de la référence : on refuse plutôt
// que de deviner.

func validate(_ input: SortInput) throws(SortError) {
  var seenCategories = Set<String>()
  for category in input.categories {
    try checkId(category.id, "category")
    guard seenCategories.insert(category.id).inserted else {
      throw .duplicateCategory(category.id)
    }
  }
  var seenItems = Set<String>()
  for item in input.items {
    try checkId(item.id, "item")
    guard seenItems.insert(item.id).inserted else { throw .duplicateItem(item.id) }
    if let productId = item.productId { try checkId(productId, "item.product_id") }
    if let categoryId = item.categoryId { try checkId(categoryId, "item.category_id") }
  }
  if case .product(let productId) = input.start { try checkId(productId, "start.product_id") }
  for id in input.previousOrder ?? [] { try checkId(id, "previous_order") }
  guard let snapshot = input.snapshot else { return }
  for edge in snapshot.edges {
    try checkId(edge.a, "edge.a")
    try checkId(edge.b, "edge.b")
    if edge.weightQ < 0 { throw .negativeWeight(context: "\(edge.a)-\(edge.b)", weightQ: edge.weightQ) }
  }
  for entry in snapshot.entries {
    try checkId(entry.productId, "entry.product_id")
    if entry.weightQ < 0 { throw .negativeWeight(context: "entry \(entry.productId)", weightQ: entry.weightQ) }
  }
}

private func checkId(_ id: String, _ field: String) throws(SortError) {
  guard isValidId(id) else { throw .invalidId(field: field, value: id) }
}
