import FlatlinkCommand
import Foundation

let version = "1.1.2"

exit(run(Array(CommandLine.arguments.dropFirst()), version: version))
