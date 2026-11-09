import Testing
@testable import TowerApp

@Test func fontScaleStepsByTenthsAndStopsAtItsBounds() {
    #expect(FontScale.standard.value == 1.0)
    #expect(FontScale.standard.bigger().bigger().bigger().value == 1.3)
    #expect(FontScale.standard.smaller().value == 0.9)

    var s = FontScale.standard
    for _ in 0..<30 { s = s.bigger() }
    #expect(s.value == 2.0)
    for _ in 0..<30 { s = s.smaller() }
    #expect(s.value == 0.8)
}

@Test func fontScaleRestoresAValidStoredValueAndFallsBackToOne() {
    #expect(FontScale(stored: 1.5).value == 1.5)
    #expect(FontScale(stored: 1.23).value == 1.2)
    #expect(FontScale(stored: 0.8).value == 0.8)
    #expect(FontScale(stored: 2.0).value == 2.0)
    #expect(FontScale(stored: 2.5).value == 1.0)
    #expect(FontScale(stored: 0.5).value == 1.0)
    #expect(FontScale(stored: .nan).value == 1.0)
    #expect(FontScale(stored: .infinity).value == 1.0)
}
