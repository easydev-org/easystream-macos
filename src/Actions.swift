import ApplicationServices
import Foundation

/// Actions maps the goa11y action vocabulary onto AX actions/attributes —
/// the same names the CLI `action` command and Provider accept.
enum Actions {
    static func perform(_ action: String, on el: AXNode, value: String?) throws {
        switch action {
        case "press", "activate":
            try act(el, kAXPressAction)
        case "focus":
            el.set(kAXFocusedAttribute, kCFBooleanTrue)
        case "blur":
            // Blur = move focus to the app (best effort: clear AXFocused).
            el.set(kAXFocusedAttribute, kCFBooleanFalse)
        case "set-value", "type-text":
            guard let v = value else { throw A11yError("action \(action) needs --value") }
            if el.set(kAXValueAttribute, v as CFTypeRef) != .success {
                throw A11yError("cannot set value")
            }
        case "toggle":
            // AX has no generic toggle; press is the closest (checkbox/switch).
            try act(el, kAXPressAction)
        case "expand":
            if el.actionNames().contains("AXExpand") { try act(el, "AXExpand") }
            else { try act(el, kAXPressAction) }
        case "collapse":
            if el.actionNames().contains("AXCollapse") { try act(el, "AXCollapse") }
            else { try act(el, kAXPressAction) }
        case "show-menu":
            try act(el, "AXShowMenu")
        case "increment":
            try act(el, kAXIncrementAction)
        case "decrement":
            try act(el, kAXDecrementAction)
        case "scroll-into-view":
            try act(el, "AXScrollToVisible")
        case "select":
            // Select a child row/option: press it.
            try act(el, kAXPressAction)
        case "close":
            if el.actionNames().contains("AXClose") { try act(el, "AXClose") }
            else { try act(el, kAXPressAction) }
        case "minimize":
            el.set("AXMinimized", kCFBooleanTrue)
        case "maximize":
            el.set("AXFullScreen", kCFBooleanTrue)
        case "enter-fullscreen":
            el.set("AXFullScreen", kCFBooleanTrue)
        case "restore":
            el.set("AXMinimized", kCFBooleanFalse)
            el.set("AXFullScreen", kCFBooleanFalse)
        default:
            // Unknown action: try it verbatim as an AX action name.
            try act(el, action)
        }
    }

    private static func act(_ el: AXNode, _ name: String) throws {
        let err = el.perform(name)
        if err != .success {
            throw A11yError("AX action \(name) failed (\(err.rawValue))")
        }
    }
}
