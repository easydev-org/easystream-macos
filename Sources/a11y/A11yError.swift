import Foundation

/// A11yError is the one error type the CLI turns into `error: ...` + exit 1,
/// mirroring goa11y's PlatformErr.
struct A11yError: Error, CustomStringConvertible {
    let message: String
    init(_ m: String) { message = m }
    var description: String { message }
}

func unsupported(_ m: String) -> A11yError { A11yError("unsupported: \(m)") }
