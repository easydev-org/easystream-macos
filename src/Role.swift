import Foundation

/// Role maps AX role strings ("AXButton") to the goa11y/xa11y vocabulary
/// (lower_snake_case: "button"), which is what `tree`/`find -o pretty` print.
enum Role {
    static func name(_ axRole: String) -> String {
        var s = axRole
        if s.hasPrefix("AX") { s = String(s.dropFirst(2)) }
        // CamelCase -> snake_case (e.g. "RadioButton" -> "radio_button").
        var out = ""
        for (i, ch) in s.enumerated() {
            if ch.isUppercase {
                if i > 0 { out.append("_") }
                out.append(Character(ch.lowercased()))
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
