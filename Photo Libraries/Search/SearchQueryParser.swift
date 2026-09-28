import Foundation

nonisolated struct NumericSearchConstraint: Sendable {
    enum Comparison: String, Sendable {
        case equal = "="
        case greaterThan = ">"
        case greaterThanOrEqual = ">="
        case lessThan = "<"
        case lessThanOrEqual = "<="
    }

    let comparison: Comparison
    let value: Int
}

nonisolated struct ParsedSearchQuery: Sendable {
    var freeText = ""
    var favorite: Bool?
    var width: NumericSearchConstraint?
    var height: NumericSearchConstraint?
    var exactWidth: Int?
    var exactHeight: Int?
    var mediaType: String?
    var library: String?
    var city: String?
    var country: String?
    var place: String?
    var dateStart: Date?
    var dateEnd: Date?

    var isEmpty: Bool {
        freeText.isEmpty && favorite == nil && width == nil && height == nil &&
            exactWidth == nil && exactHeight == nil && mediaType == nil &&
            library == nil && city == nil && country == nil && place == nil &&
            dateStart == nil && dateEnd == nil
    }
}

nonisolated enum SearchQueryParser {
    static func parse(_ rawQuery: String) -> ParsedSearchQuery {
        var result = ParsedSearchQuery()
        var freeTokens: [String] = []
        for token in tokens(from: rawQuery) {
            guard let separator = token.firstIndex(of: ":") else {
                freeTokens.append(token)
                continue
            }
            let field = String(token[..<separator]).lowercased()
            let rawValue = String(token[token.index(after: separator)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !rawValue.isEmpty else { continue }

            switch field {
            case "favorite", "favourite":
                result.favorite = parseBool(rawValue)
            case "width":
                result.width = parseNumeric(rawValue)
            case "height":
                result.height = parseNumeric(rawValue)
            case "dimensions", "dimension":
                let pieces = rawValue.lowercased().split(separator: "x", maxSplits: 1)
                if pieces.count == 2 {
                    result.exactWidth = Int(pieces[0])
                    result.exactHeight = Int(pieces[1])
                }
            case "type", "media":
                result.mediaType = SearchTextNormalizer.normalize(rawValue)
            case "library":
                result.library = SearchTextNormalizer.normalize(rawValue)
            case "city":
                result.city = SearchTextNormalizer.normalize(rawValue)
            case "country":
                result.country = SearchTextNormalizer.normalize(rawValue)
            case "place", "location":
                result.place = SearchTextNormalizer.normalize(rawValue)
            case "year":
                if let year = Int(rawValue) {
                    setYearRange(year, result: &result)
                }
            case "date":
                setDateRange(rawValue, result: &result)
            default:
                freeTokens.append(token)
            }
        }
        result.freeText = SearchTextNormalizer.normalize(freeTokens.joined(separator: " "))
        return result
    }

    private static func tokens(from query: String) -> [String] {
        let pattern = #"[^\s\"]+:\"[^\"]*\"|\S+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return query.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        let range = NSRange(query.startIndex..<query.endIndex, in: query)
        return expression.matches(in: query, range: range).compactMap {
            guard let range = Range($0.range, in: query) else { return nil }
            return String(query[range])
        }
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "yes", "1": true
        case "false", "no", "0": false
        default: nil
        }
    }

    private static func parseNumeric(_ value: String) -> NumericSearchConstraint? {
        let operators: [(String, NumericSearchConstraint.Comparison)] = [
            (">=", .greaterThanOrEqual), ("<=", .lessThanOrEqual),
            (">", .greaterThan), ("<", .lessThan), ("=", .equal)
        ]
        for (prefix, comparison) in operators where value.hasPrefix(prefix) {
            guard let number = Int(value.dropFirst(prefix.count)) else { return nil }
            return NumericSearchConstraint(comparison: comparison, value: number)
        }
        guard let number = Int(value) else { return nil }
        return NumericSearchConstraint(comparison: .equal, value: number)
    }

    private static func setYearRange(_ year: Int, result: inout ParsedSearchQuery) {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = year
        components.month = 1
        components.day = 1
        guard let start = components.date,
              let end = Calendar.current.date(byAdding: .year, value: 1, to: start) else { return }
        result.dateStart = start
        result.dateEnd = end
    }

    private static func setDateRange(_ value: String, result: inout ParsedSearchQuery) {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        guard let start = formatter.date(from: value),
              let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return }
        result.dateStart = start
        result.dateEnd = end
    }
}
