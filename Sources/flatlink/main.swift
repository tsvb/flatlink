import FlatlinkCore
import Foundation

let version = "0.1.0"
let tool = "flatlink"

let usage = """
usage: \(tool) [-n] [--prune] [--skip-paired-jpegs] [--ext EXT]... SOURCE DEST

Build a flat folder of symlinks to every image under a folder tree, for DxO PhotoLab.

DxO PhotoLab's folder browser shows only the images at the top level of a
folder. It follows symlinks, so opening DEST in PhotoLab shows every image
under SOURCE in one grid. Link names encode the path below SOURCE:
    2024/Iceland/IMG_0001.CR3  ->  2024__Iceland__IMG_0001.CR3

Re-running is safe: existing links are kept and only new images are linked.
Nothing is written anywhere but DEST, and only symlinks are ever created or
removed there.

arguments:
  SOURCE                 folder tree containing images
  DEST                   flat folder to fill with symlinks (created if missing)

options:
  -n, --dry-run          show what would change, change nothing
  --prune                remove links in DEST whose original no longer exists
  --skip-paired-jpegs    leave out a JPEG when a RAW of the same name is in the
                         same folder (RAW+JPEG shooting), so each shot shows once
  --ext EXT              only link this extension; repeatable (--ext cr3 --ext jpg).
                         Default: JPEG, TIFF, HEIC, PNG and 24 RAW formats
  -h, --help             show this help
  --version              show the version

exit status: 0 success, 1 some links could not be created or removed, 64 usage error

Not affiliated with DxO. PhotoLab is a trademark of DxO Labs.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(tool): error: \(message)\nRun '\(tool) --help' for usage.\n".utf8))
    exit(64)
}

var options = FlattenOptions(source: "", dest: "")
var extensions: Set<String> = []
var positional: [String] = []
var args = CommandLine.arguments.dropFirst()[...]

while let arg = args.popFirst() {
    switch arg {
    case "-h", "--help": print(usage); exit(0)
    case "--version": print("\(tool) \(version)"); exit(0)
    case "-n", "--dry-run": options.dryRun = true
    case "--prune": options.prune = true
    case "--skip-paired-jpegs": options.skipPairedJPEGs = true
    case "--ext":
        guard let value = args.popFirst(), !value.hasPrefix("-") else { fail("--ext needs a value, e.g. --ext cr3") }
        extensions.insert(value.lowercased().trimmingPrefix(".").description)
    case _ where arg.hasPrefix("--ext="):
        extensions.insert(arg.dropFirst("--ext=".count).lowercased().trimmingPrefix(".").description)
    case "--": positional += args; args = []
    case _ where arg.hasPrefix("-") && arg != "-": fail("unknown option \(arg)")
    default: positional.append(arg)
    }
}

guard positional.count == 2 else { fail("expected SOURCE and DEST, got \(positional.count) argument(s)") }
options.source = positional[0]
options.dest = positional[1]
if !extensions.isEmpty { options.extensions = extensions }

do {
    let summary = try flatten(options) { event in
        switch event {
        case .link(let name): print("link  \(name)")
        case .prune(let name): print("prune \(name)")
        case .skipPointsElsewhere(let name):
            FileHandle.standardError.write(Data("skip (link exists, points elsewhere): \(name)\n".utf8))
        case .skipRealFile(let name):
            FileHandle.standardError.write(Data("skip (real file in the way): \(name)\n".utf8))
        case .failed(let name, let message):
            FileHandle.standardError.write(Data("failed: \(name): \(message)\n".utf8))
        }
    }
    let verb = options.dryRun ? "would create" : "created"
    var line = "\n\(verb) \(summary.created), kept \(summary.kept), skipped \(summary.skipped), pruned \(summary.pruned)"
    if options.skipPairedJPEGs { line += ", left out \(summary.paired) paired JPEGs" }
    if summary.failed > 0 { line += ", failed \(summary.failed)" }
    print("\(line)  ->  \(summary.dest)")
    exit(summary.failed > 0 ? 1 : 0)
} catch let error as FlattenError {
    fail(error.description)
} catch {
    FileHandle.standardError.write(Data("\(tool): \(error.localizedDescription)\n".utf8))
    exit(1)
}
