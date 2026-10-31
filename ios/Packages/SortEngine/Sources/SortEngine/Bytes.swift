// Comparaisons octet par octet en UTF-8 : jamais `<` sur `String` (ordre Unicode), ni
// comparaison sensible à la locale (shared/README.md, « Portage »).

/// Compare deux chaînes sur leurs octets UTF-8 : -1, 0 ou 1.
func compareBytes(_ a: String, _ b: String) -> Int {
  if a == b { return 0 }
  var x = a.utf8.makeIterator()
  var y = b.utf8.makeIterator()
  while true {
    switch (x.next(), y.next()) {
    case (nil, nil): return 0
    case (nil, _): return -1
    case (_, nil): return 1
    case (let u?, let v?) where u != v: return u < v ? -1 : 1
    default: continue
    }
  }
}

/// Vrai si `a` précède strictement `b` dans l'ordre des octets UTF-8.
func bytesPrecede(_ a: String, _ b: String) -> Bool {
  compareBytes(a, b) < 0
}

/// Identifiant valide : ASCII `[0-9a-z-]+`, non vide.
func isValidId(_ id: String) -> Bool {
  !id.utf8.isEmpty
    && id.utf8.allSatisfy { byte in
      (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
        || byte == UInt8(ascii: "-")
    }
}
