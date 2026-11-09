import Foundation

/// Ayrıntılar görünümünün sütunları; aynı zamanda sıralama ölçütleri.
public enum SortColumn: String, CaseIterable, Sendable {
    case name, modified, kind, size
}

public struct FileSort: Equatable, Sendable {
    public var column: SortColumn
    public var ascending: Bool

    public init(column: SortColumn = .name, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }

    /// Windows gibi: klasörler her zaman dosyalardan önce; adlar doğal sırada ("Dosya 2" < "Dosya 10").
    /// Eşit değerlerde ad (artan) belirleyicidir.
    public func sorted(_ items: [FileItem]) -> [FileItem] {
        items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let result: ComparisonResult
            switch column {
            case .name: result = a.displayName.localizedStandardCompare(b.displayName)
            case .modified: result = Self.compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
            case .kind: result = a.kind.localizedStandardCompare(b.kind)
            case .size: result = Self.compare(a.size ?? -1, b.size ?? -1)
            }
            if result == .orderedSame {
                return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
}

/// Boyut metinleri.
public enum SizeFormat {
    /// Windows Gezgini'nin Boyut sütunu gibi her zaman KB, yukarı yuvarlanmış: 1 bayt → "1 KB", 1.263.616 bayt → "1.234 KB".
    public static func kilobytes(_ bytes: Int64, locale: Locale = .current) -> String {
        let kb = bytes <= 0 ? 0 : (bytes + 1023) / 1024
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return (f.string(from: NSNumber(value: kb)) ?? "\(kb)") + " KB"
    }
}
