import FlatlinkCommand
import Foundation

let version = "1.1.0"

exit(run(Array(CommandLine.arguments.dropFirst()), version: version))
