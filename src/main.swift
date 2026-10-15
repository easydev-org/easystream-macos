import Foundation

// Entry point: `a11y <command> [...]`, mirroring the goa11y CLI exit codes
// (0 ok, 1 error).
let argv = Array(CommandLine.arguments.dropFirst())
do {
    try CLI.run(argv)
    exit(0)
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
