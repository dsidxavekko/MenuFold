import Testing
@testable import MenuFoldCore

@Suite struct CalculatorTests {
    private func value(_ s: String) -> String? { Calculator.evaluate(s)?.value }

    @Test func arithmetic() {
        #expect(value("2+2") == "4")
        #expect(value("2+3*4") == "14")
        #expect(value("(2+3)*4") == "20")
        #expect(value("2^10") == "1024")
        #expect(value("2^3^2") == "512")
        #expect(value("-2^2") == "-4")
        #expect(value("10/4") == "2.5")
        #expect(value("7 mod 3") == "1")
        #expect(value("0.1+0.2") == "0.3")
        #expect(value("2,5*2") == "5")
        #expect(value("200*10%") == "20")
        #expect(value("1e3+1") == "1001")
        #expect(value("2 × 3") == "6")
    }

    @Test func functions() {
        #expect(value("sqrt(16)") == "4")
        #expect(value("sqrt(16)+1") == "5")
        #expect(value("abs(-3)") == "3")
        #expect(value("2*pi")?.hasPrefix("6.28318") == true)
    }

    @Test func rejects() {
        for q in ["5", "-5", "3.14", "(5)", "pi", "1password", "c++", "node.js", "7-zip", "2+", "(2+3",
                  "1/0", "sqrt(-1)", "sqrt", "xcode", "", "1+a", "2+2)", "a+b"] {
            #expect(Calculator.evaluate(q) == nil, "\(q)")
        }
    }

    @Test func deepNestingDoesNotCrash() {
        let q = String(repeating: "(", count: 5000) + "1" + String(repeating: ")", count: 5000)
        #expect(Calculator.evaluate(q) == nil)
        #expect(Calculator.evaluate(String(repeating: "-", count: 400) + "1+1") == nil)
    }

    @Test func conversions() {
        #expect(value("1 km in m") == "1000")
        #expect(value("5 km in mi")?.hasPrefix("3.1068") == true)
        #expect(value("100 f to c")?.hasPrefix("37.7777") == true)
        #expect(value("0 c in k") == "273.15")
        #expect(value("2 gb in mb") == "2000")
        #expect(value("1gib to mib") == "1024")
        #expect(value("2 h in min") == "120")
        #expect(value("1 kg to lb")?.hasPrefix("2.2046") == true)
        #expect(value("1 ft in in") == "12")
        #expect(value("2,5 km to m") == "2500")
        #expect(Calculator.evaluate("5 km in mi")?.display.contains("km") == true)
    }

    @Test func conversionRejects() {
        #expect(Calculator.evaluate("5 km in kg") == nil)
        #expect(Calculator.evaluate("5 foo in bar") == nil)
        #expect(Calculator.evaluate("km in mi") == nil)
        #expect(Calculator.evaluate("photoshop to lightroom") == nil)
    }
}

@MainActor @Suite struct GridModelCalculatorTests {
    @Test func scopesAndSelection() {
        let m = GridModel.preview
        m.query = "2+2"
        #expect(m.calculatorResult?.value == "4")
        #expect(m.navigableSections.first == ["calc"])
        m.query = ">2+2"
        #expect(m.calculatorResult == nil)
        m.query = "?2+2"
        #expect(m.calculatorResult == nil)
        m.query = "1password"
        #expect(m.calculatorResult == nil)
        m.query = ""
        #expect(m.calculatorResult == nil)
    }
}
