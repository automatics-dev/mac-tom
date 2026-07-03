import SwiftUI

// MARK: - NavigationSplitViewVisibility @AppStorage Bridge
//
// NavigationSplitViewVisibility, RawRepresentable conformance sağlamadığı için
// doğrudan @AppStorage ile saklanamaz (RESEARCH.md Assumption A1). Bu extension
// String tabanlı dönüşüm sağlar; @AppStorage("tom.splitViewColumnVisibility")
// tarafından tüketilir (NAV-02, NAV-03).

extension NavigationSplitViewVisibility {
    /// String temsili — @AppStorage ile uyumlu.
    var rawStringValue: String {
        switch self {
        case .all:          return "all"
        case .doubleColumn: return "doubleColumn"
        case .detailOnly:   return "detailOnly"
        default:            return "all"   // .automatic veya bilinmeyen değerler -> .all
        }
    }

    /// String'den geri dönüşüm. Geçersiz değer için nil döner; çağıran taraf
    /// `?? .all` fallback'ı ile güvenli başlangıç değerini sağlamalıdır.
    init?(rawStringValue: String) {
        switch rawStringValue {
        case "all":          self = .all
        case "doubleColumn": self = .doubleColumn
        case "detailOnly":   self = .detailOnly
        default:             return nil
        }
    }
}
