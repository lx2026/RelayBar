import XCTest
@testable import MarkdownRendering

final class MathTypesetterTests: XCTestCase {
    func testOrdinaryFormulasAreTypeset() throws {
        XCTAssertTrue(MathTypesetter.canParse("x^2 + y_1"))
        let inline = try XCTUnwrap(MathTypesetter.image(for: "\\frac{a}{b}", display: false))
        let display = try XCTUnwrap(MathTypesetter.image(for: "\\frac{a}{b}", display: true))
        XCTAssertLessThanOrEqual(inline.height, 26)
        XCTAssertGreaterThan(display.height, inline.height)
        XCTAssertGreaterThan(inline.descent, 0, "a fraction hangs below the baseline")
        XCTAssertEqual(Array(inline.png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    /// The typesetter traps on these although its parser accepts them, so they must stay as source.
    func testFormulasTheTypesetterCannotSurviveAreRefused() {
        for formula in ["x\\textcolor{#ff0000}{}", "x\\textcolor{red}{\\frac{a}{b}}", "\\color{red}x", "\\colorbox{red}{x}",
                        "\\frac{\\textcolor{red}{}}{b}", "\\sqrt{x\\textcolor{red}{}}", "x^{\\textcolor{red}{y}}"] {
            XCTAssertFalse(MathTypesetter.canParse(formula), formula)
            XCTAssertNil(MathTypesetter.image(for: formula, display: false), formula)
            XCTAssertNil(MathTypesetter.image(for: formula, display: true), formula)
        }
    }

    func testDeeplyNestedAndOversizedFormulasAreRefusedBeforeParsing() {
        let depth = MathTypesetter.maximumNestingDepth + 1
        for formula in [
            String(repeating: "{", count: depth) + "x" + String(repeating: "}", count: depth),
            String(repeating: "\\sqrt{", count: depth) + "x" + String(repeating: "}", count: depth),
            String(repeating: "\\left(", count: depth) + "x" + String(repeating: "\\right)", count: depth),
            String(repeating: "x", count: ObsidianMarkdownCompatibility.maximumFormulaCharacterCount + 1)
        ] {
            XCTAssertFalse(MathTypesetter.canParse(formula))
            XCTAssertNil(MathTypesetter.image(for: formula, display: true))
        }
        XCTAssertTrue(MathTypesetter.canParse(String(repeating: "{", count: 8) + "x" + String(repeating: "}", count: 8)))
    }

    /// Passing means none of these trapped: a trap here would take the app down from a document's text.
    func testEdgeCaseFormulasNeverTrap() {
        let singles = ["{}", "x^{}", "x_{}", "\\frac{}{}", "\\frac{a}{}", "\\frac{}{b}", "\\sqrt{}", "\\sqrt[]{}", "\\sqrt[3]{}", "\\sqrt[]{x}",
            "\\overline{}", "\\underline{}", "\\hat{}", "\\vec{}", "\\bar{}", "\\tilde{}", "\\widehat{}", "\\left(\\right)", "\\left.\\right.", "\\left(x\\right.", "\\left\\{\\right\\}",
            "\\begin{matrix}\\end{matrix}", "\\begin{matrix}&\\\\&\\end{matrix}", "\\begin{pmatrix}a&b\\\\c\\end{pmatrix}", "\\begin{cases}\\end{cases}", "\\begin{cases}a&b\\\\\\end{cases}",
            "\\begin{aligned}&\\end{aligned}", "\\begin{aligned}a&=b\\\\&=c\\end{aligned}", "\\begin{eqnarray}a&=&b\\end{eqnarray}", "\\begin{gather}a\\\\b\\end{gather}", "\\begin{split}a&b\\end{split}",
            "\\begin{bmatrix}\\end{bmatrix}", "\\begin{vmatrix}a\\end{vmatrix}", "\\begin{Bmatrix}a&\\end{Bmatrix}", "\\begin{smallmatrix}a\\end{smallmatrix}", "\\begin{array}{cc}a&b\\end{array}",
            "\\sum_{}^{}", "\\int_{}^{}", "\\lim_{}", "\\prod^{}", "\\sum\\limits_{}", "\\int\\nolimits_a", "\\limits", "\\nolimits",
            "\\mathrm{}", "\\text{}", "\\mathbf{}", "\\mathbb{}", "\\mathcal{}", "\\mathfrak{}", "\\mathsf{}", "\\mathit{}", "\\mathtt{}", "\\operatorname{}", "\\operatorname{sin}",
            "\\displaystyle", "\\textstyle x", "\\scriptstyle", "\\scriptscriptstyle x", "x\\,", "\\quad", "\\qquad", "\\;", "\\!", "\\ ", "\\mkern3mu", "\\hspace{1em}",
            "^2", "_2", "{}^{}", "{}_{}", "x''", "x'^2", "\\prime", "x^{y^{z^{w}}}", "x_{y_{z_{w}}}", "x^y^z", "x_y_z",
            "\\binom{}{}", "\\binom{n}{k}", "a\\over b", "{\\over}", "\\over", "{a\\atop b}", "\\atop", "a\\choose b", "\\choose", "{a\\brace b}", "{a\\brack b}",
            "\\not", "\\not=", "-", "+", "=", "\\cdot", "\\\\", "&", "a&b", "a\\\\b", "é", "😀", "\\alpha\\beta\\gamma", "\\infty", "\\partial", "\\nabla",
            "\\dfrac{a}{b}", "\\tfrac{a}{b}", "\\cfrac{a}{b}", "\\stackrel{a}{b}", "\\overset{a}{b}", "\\underset{a}{b}", "\\overbrace{a}", "\\underbrace{a}_{b}", "\\boxed{a}", "\\cancel{a}",
            "\\frac{\\frac{}{}}{}", "\\sqrt{\\sqrt{}}", "\\hat{\\hat{}}", "\\overline{\\frac{}{}}", "\\left(\\frac{}{}\\right)", "\\sqrt{\\left(\\right)}", "\\hat{\\frac{a}{b}}", "\\vec{\\sqrt{x}}",
            "\\left(\\begin{matrix}a\\end{matrix}\\right)", "\\frac{\\begin{matrix}a\\end{matrix}}{b}", "x^{\\begin{matrix}a\\end{matrix}}", "\\sum_{\\frac{}{}}^{\\sqrt{}}",
            "\\color{red}x", "\\textcolor{red}{x}", "\\colorbox{red}{x}", "x\\textcolor{#ff0000}{}", "x\\textcolor{red}{\\frac{a}{b}}", "\\frac{\\textcolor{red}{}}{b}", "\\sqrt{x\\textcolor{red}{}}",
            "\\left(", "\\right)", "\\begin{matrix}", "\\end{matrix}", "{", "}", "\\", "\\frac", "\\sqrt", "\\sqrt[", "\\hat", "$", "%", "#", "~", "x~y", "\\#", "\\%", "\\&", "\\_", "\\{\\}",
            "\\Large x", "\\tiny x", "\\rm x", "\\bf x", "\\it x", "\\cal x", "\\mathop{x}", "\\mathbin{x}", "\\mathrel{x}", "\\mathord{x}", "\\phantom{x}", "\\hphantom{}", "\\vphantom{}", "\\smash{x}",
            "1,000.5", "a.b", "..", "\\ldots", "\\cdots", "\\vdots", "\\ddots", "\\to", "\\rightarrow", "\\Rightarrow", "\\mapsto", "\\langle x\\rangle", "\\left\\langle x\\right\\rangle", "\\|x\\|", "\\left\\|x\\right\\|",
            "\\lfloor x\\rfloor", "\\lceil x\\rceil", "|x|", "\\left|x\\right|", "\\mathrm{d}x", "\\frac{d}{dx}", "e^{i\\pi}+1=0", "\\substack{a\\\\b}", "\\tag{1}", "\\label{a}", "\\nonumber"]
        var typeset = 0
        for formula in singles + singles.map({ "x" + $0 }) + singles.map({ $0 + "=" }) + singles.map({ "\\frac{a}{b}" + $0 }) {
            for display in [false, true] where MathTypesetter.image(for: formula, display: display) != nil { typeset += 1 }
        }
        XCTAssertGreaterThan(typeset, 500)
    }
}
