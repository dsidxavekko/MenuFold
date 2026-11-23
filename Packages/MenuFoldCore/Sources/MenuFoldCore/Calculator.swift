import Foundation

/// The answer to a calculator/converter query: what the row shows and what Return copies.
public struct CalculatorResult: Equatable, Sendable {
    /// Shown in the row, e.g. "4" or "5 km = 3,10686 mi" (locale decimal separator).
    public let display: String
    /// Copied to the pasteboard: the plain number (dot, no grouping), e.g. "3.10686".
    public let value: String
}

/// Safe calculator: a hand-written recursive-descent parser (no NSExpression, no eval) and
/// conversions between fixed units. No network, so no currencies.
///
/// A query counts only when it really calculates: it needs an operator, a percent sign or a
/// function call (a bare number never does), or the "<number> <unit> in <unit>" shape. Anything the
/// parser does not fully understand ("1password", "c++", "node.js") is not a calculation.
public enum Calculator {
    static let maxLength = 120
    static let maxDepth = 48

    public static func evaluate(_ raw: String) -> CalculatorResult? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxLength else { return nil }
        if let converted = convert(text) { return converted }
        var parser = Parser(text)
        guard let v = parser.parse(), v.isFinite else { return nil }
        let value = plain(v)
        return CalculatorResult(display: formatted(v), value: value)
    }

    // MARK: Formatting

    /// Ten significant digits, which hides binary noise like 0.1 + 0.2.
    static func rounded(_ v: Double) -> Double {
        Double(String(format: "%.10g", v)) ?? v
    }

    static func plain(_ v: Double) -> String {
        let r = rounded(v)
        if r == 0 { return "0" }
        if abs(r) >= 1e15 || abs(r) < 1e-9 { return String(format: "%.10g", r) }
        var s = String(format: "%.12f", r)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func formatted(_ v: Double) -> String {
        let r = rounded(v)
        if r == 0 { return "0" }
        if abs(r) >= 1e15 || abs(r) < 1e-9 { return String(format: "%.10g", r) }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = .current
        f.maximumFractionDigits = 10
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: r)) ?? plain(v)
    }

    // MARK: Conversion

    private static let separators: Set<String> = ["in", "to", "as", "->", "=>", "у", "в", "до"]

    /// "5 km in mi", "100 f to c", "2gb to mb".
    static func convert(_ text: String) -> CalculatorResult? {
        // number, unit, separator word, unit
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var number = "", fromName = "", toName = ""
        switch parts.count {
        case 3 where separators.contains(parts[1].lowercased()) == false:
            return nil
        case 4:
            // "5 km in mi"
            guard separators.contains(parts[2].lowercased()) else { return nil }
            number = parts[0]; fromName = parts[1]; toName = parts[3]
        case 3:
            // "5km in mi": number glued to the unit
            guard separators.contains(parts[1].lowercased()) else { return nil }
            let head = parts[0]
            guard let split = head.firstIndex(where: { !($0.isNumber || ".,+-".contains($0)) }),
                  split != head.startIndex else { return nil }
            number = String(head[..<split]); fromName = String(head[split...]); toName = parts[2]
        default:
            return nil
        }
        guard let amount = parseNumber(number),
              let from = Unit.named(fromName), let to = Unit.named(toName),
              from.dimension == to.dimension else { return nil }
        let result = (amount * from.factor + from.offset - to.offset) / to.factor
        guard result.isFinite else { return nil }
        return CalculatorResult(
            display: "\(formatted(amount)) \(from.label) = \(formatted(result)) \(to.label)",
            value: plain(result)
        )
    }

    static func parseNumber(_ s: String) -> Double? {
        guard let first = s.first, first.isNumber || first == "-" || first == "+" else { return nil }
        let t = s.replacingOccurrences(of: ",", with: ".")
        guard t.filter({ $0 == "." }).count <= 1, let v = Double(t), v.isFinite else { return nil }
        return v
    }

    struct Unit {
        enum Dimension { case length, mass, temperature, data, time }
        let dimension: Dimension
        let label: String
        /// base = value * factor + offset (base: m, g, K, byte, s).
        let factor: Double
        var offset: Double = 0

        static func named(_ raw: String) -> Unit? {
            var key = raw.lowercased()
            if key.hasPrefix("°") { key.removeFirst() }
            return table[key]
        }

        static let table: [String: Unit] = {
            var t: [String: Unit] = [:]
            func add(_ names: [String], _ d: Dimension, _ label: String, _ factor: Double, _ offset: Double = 0) {
                let u = Unit(dimension: d, label: label, factor: factor, offset: offset)
                for n in names { t[n] = u }
            }
            // Length (m)
            add(["mm", "мм"], .length, "mm", 0.001)
            add(["cm", "см"], .length, "cm", 0.01)
            add(["m", "м"], .length, "m", 1)
            add(["km", "км"], .length, "km", 1000)
            add(["in", "inch", "inches", "дюйм"], .length, "in", 0.0254)
            add(["ft", "foot", "feet", "фут"], .length, "ft", 0.3048)
            add(["yd", "yard", "yards"], .length, "yd", 0.9144)
            add(["mi", "mile", "miles", "миля", "милі"], .length, "mi", 1609.344)
            // Mass (g)
            add(["mg", "мг"], .mass, "mg", 0.001)
            add(["g", "г"], .mass, "g", 1)
            add(["kg", "кг"], .mass, "kg", 1000)
            add(["t", "tonne", "т"], .mass, "t", 1_000_000)
            add(["oz", "ounce", "ounces"], .mass, "oz", 28.349523125)
            add(["lb", "lbs", "pound", "pounds", "фунт"], .mass, "lb", 453.59237)
            // Temperature (K)
            add(["c", "celsius", "°c", "ц"], .temperature, "°C", 1, 273.15)
            add(["f", "fahrenheit", "°f"], .temperature, "°F", 5.0 / 9.0, 273.15 - 32 * 5.0 / 9.0)
            add(["k", "kelvin"], .temperature, "K", 1)
            // Data (bytes; kb/mb/gb decimal like macOS, kib/mib/gib binary)
            add(["bit", "bits"], .data, "bit", 0.125)
            add(["b", "byte", "bytes", "байт"], .data, "B", 1)
            add(["kb", "кб"], .data, "KB", 1e3)
            add(["mb", "мб"], .data, "MB", 1e6)
            add(["gb", "гб"], .data, "GB", 1e9)
            add(["tb", "тб"], .data, "TB", 1e12)
            add(["kib"], .data, "KiB", 1024)
            add(["mib"], .data, "MiB", 1_048_576)
            add(["gib"], .data, "GiB", 1_073_741_824)
            add(["tib"], .data, "TiB", 1_099_511_627_776)
            // Time (s)
            add(["ms", "мс"], .time, "ms", 0.001)
            add(["s", "sec", "secs", "second", "seconds", "с", "сек"], .time, "s", 1)
            add(["min", "mins", "minute", "minutes", "хв"], .time, "min", 60)
            add(["h", "hr", "hrs", "hour", "hours", "год"], .time, "h", 3600)
            add(["d", "day", "days", "дн", "день"], .time, "d", 86400)
            add(["w", "wk", "week", "weeks", "тиж"], .time, "wk", 604_800)
            return t
        }()
    }

    // MARK: Parser

    private enum Token: Equatable {
        case number(Double)
        case name(String)
        case op(Character)   // + - * / ^ % ( )
    }

    private struct Parser {
        var tokens: [Token] = []
        var pos = 0
        var depth = 0
        var ok = true
        /// Set once something calculates (binary operator, percent, function).
        var calculates = false

        init(_ text: String) {
            tokens = Parser.tokenize(text) ?? []
            if tokens.isEmpty { ok = false }
        }

        static func tokenize(_ text: String) -> [Token]? {
            let chars = Array(text)
            var out: [Token] = []
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if c.isWhitespace { i += 1; continue }
                if c.isASCII && c.isNumber || ((c == "." || c == ",") && i + 1 < chars.count && chars[i + 1].isASCII && chars[i + 1].isNumber) {
                    var s = ""
                    var seenDot = false
                    while i < chars.count {
                        let d = chars[i]
                        if d.isASCII && d.isNumber { s.append(d); i += 1 }
                        else if (d == "." || d == ","), !seenDot, i + 1 < chars.count, chars[i + 1].isASCII, chars[i + 1].isNumber {
                            seenDot = true; s.append("."); i += 1
                        } else { break }
                    }
                    // exponent: 1e3, 2E-4
                    if i < chars.count, chars[i] == "e" || chars[i] == "E" {
                        var j = i + 1
                        if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
                        if j < chars.count, chars[j].isASCII, chars[j].isNumber {
                            var e = "e"
                            if chars[i + 1] == "-" { e += "-" }
                            i = j
                            while i < chars.count, chars[i].isASCII, chars[i].isNumber { e.append(chars[i]); i += 1 }
                            s += e
                        }
                    }
                    guard let v = Double(s) else { return nil }
                    out.append(.number(v))
                } else if c.isLetter {
                    var s = ""
                    while i < chars.count, chars[i].isLetter || (chars[i].isNumber && !s.isEmpty) { s.append(chars[i]); i += 1 }
                    if s == "π" { out.append(.number(Double.pi)) } else { out.append(.name(s.lowercased())) }
                } else {
                    switch c {
                    case "+", "*", "/", "^", "%", "(", ")": out.append(.op(c))
                    case "-", "−", "–": out.append(.op("-"))
                    case "×", "·": out.append(.op("*"))
                    case "÷", ":": out.append(.op("/"))
                    default: return nil
                    }
                    i += 1
                }
            }
            return out
        }

        mutating func parse() -> Double? {
            guard ok else { return nil }
            let v = expression()
            guard ok, pos == tokens.count, calculates else { return nil }
            return v
        }

        private var peek: Token? { pos < tokens.count ? tokens[pos] : nil }

        private mutating func fail() -> Double { ok = false; return 0 }

        private mutating func expression() -> Double {
            var v = term()
            while ok, case .op(let o)? = peek, o == "+" || o == "-" {
                pos += 1
                let r = term()
                calculates = true
                v = o == "+" ? v + r : v - r
            }
            return v
        }

        private mutating func term() -> Double {
            var v = unary()
            while ok {
                if case .op(let o)? = peek, o == "*" || o == "/" {
                    pos += 1
                    let r = unary()
                    calculates = true
                    if o == "*" { v *= r } else {
                        if r == 0 { return fail() }
                        v /= r
                    }
                } else if case .name("mod")? = peek {
                    pos += 1
                    let r = unary()
                    calculates = true
                    if r == 0 { return fail() }
                    v = v.truncatingRemainder(dividingBy: r)
                } else { break }
            }
            return v
        }

        private mutating func unary() -> Double {
            depth += 1
            defer { depth -= 1 }
            guard depth < Calculator.maxDepth else { return fail() }
            if case .op(let o)? = peek, o == "-" || o == "+" {
                pos += 1
                let v = unary()
                return o == "-" ? -v : v
            }
            return power()
        }

        private mutating func power() -> Double {
            let base = postfix()
            if ok, case .op("^")? = peek {
                pos += 1
                calculates = true
                let e = unary()
                let r = pow(base, e)
                return r.isFinite ? r : fail()
            }
            return base
        }

        private mutating func postfix() -> Double {
            var v = primary()
            while ok, case .op("%")? = peek {
                pos += 1
                calculates = true
                v /= 100
            }
            return v
        }

        private mutating func primary() -> Double {
            guard let t = peek else { return fail() }
            pos += 1
            switch t {
            case .number(let v): return v
            case .op("("):
                depth += 1
                defer { depth -= 1 }
                guard depth < Calculator.maxDepth else { return fail() }
                let v = expression()
                guard ok, case .op(")")? = peek else { return fail() }
                pos += 1
                return v
            case .name(let n):
                if n == "pi" { return Double.pi }
                if n == "e" { return M_E }
                guard let f = Parser.functions[n], case .op("(")? = peek else { return fail() }
                pos += 1
                depth += 1
                defer { depth -= 1 }
                guard depth < Calculator.maxDepth else { return fail() }
                let arg = expression()
                guard ok, case .op(")")? = peek else { return fail() }
                pos += 1
                calculates = true
                let r = f(arg)
                return r.isFinite ? r : fail()
            default: return fail()
            }
        }

        /// `@Sendable` values: a plain function dictionary in a `static let` is shared state, which
        /// Swift 6 rejects unless the element type can cross isolation.
        static let functions: [String: @Sendable (Double) -> Double] = [
            "sqrt": { $0 >= 0 ? sqrt($0) : .nan }, "cbrt": cbrt,
            "sin": sin, "cos": cos, "tan": tan, "asin": asin, "acos": acos, "atan": atan,
            "ln": { $0 > 0 ? log($0) : .nan }, "log": { $0 > 0 ? log10($0) : .nan },
            "log2": { $0 > 0 ? log2($0) : .nan }, "exp": exp, "abs": { abs($0) },
            "round": { $0.rounded() }, "floor": { floor($0) }, "ceil": { ceil($0) },
        ]
    }
}
