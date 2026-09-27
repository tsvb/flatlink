import FlatlinkCommand
import Foundation

let version = "0.1.0"

exit(run(Array(CommandLine.arguments.dropFirst()), version: version))
