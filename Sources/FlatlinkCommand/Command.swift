import FlatlinkCore
import Foundation

let tool = "flatlink"

let usage = """
usage: \(tool) [-n] [--prune] [--skip-paired-jpegs] [--ext EXT]... SOURCE DEST

Build a flat folder of symlinks to every image under a folder tree, for DxO PhotoLab.

DxO PhotoLab's folder browser shows only the images at the top level of a
folder. It follows symlinks, so opening DEST in PhotoLab shows every image
under SOURCE in one grid. Link names encode the path below SOURCE:
    2024/Iceland/IMG_0001.CR3  ->  2024__Iceland__IMG_0001.CR3

Re-running is safe: existing links are kept and only new images are linked.
Links left broken by moving or renaming SOURCE are pointed at the new place.
Nothing is written anywhere but DEST, and only symlinks are ever created or
removed there.

arguments:
  SOURCE                 folder tree containing images
  DEST                   flat folder to fill with symlinks (created if missing)

options:
  -n, --dry-run          show what would change, change nothing
  --prune                remove links into SOURCE whose original has been deleted
  --skip-paired-jpegs    leave out a JPEG when a RAW of the same name is in the
                         same folder (RAW+JPEG shooting), so each shot shows once
  --ext EXT              only link this extension; repeatable (--ext cr3 --ext jpg)
                         or as a list (--ext cr3,jpg).
                         Default: JPEG, TIFF, HEIC, PNG and \(ImageTypes.raw.count) RAW formats
  --                     what follows is SOURCE and DEST, even if it starts with -
  -h, --help             show this help
  --version              show the version

exit status: 0 every image under SOURCE has its link, 1 some images could not be
linked or some links not removed (each is named), 64 usage error

Not affiliated with DxO. PhotoLab is a trademark of DxO Labs.
"""

/// What a command line asks for.
enum Request: Equatable {
    case help
    case version
    /// `extensions` are the ones named with --ext, in the order given.
    case flatten(FlattenOptions, extensions: [String])
}

struct UsageError: Error, Equatable {
    var message: String
}

/// Relative paths are taken from `directory`.
func parse(_ arguments: [String], directory: String) throws -> Request {
    var dryRun = false, prune = false, skipPairedJPEGs = false
    var extensions: [String] = []
    var positional: [String] = []
    var args = arguments[...]

    while let arg = args.popFirst() {
        switch arg {
        case "-h", "--help": return .help
        case "--version": return .version
        case "-n", "--dry-run": dryRun = true
        case "--prune": prune = true
        case "--skip-paired-jpegs": skipPairedJPEGs = true
        case "--ext":
            guard let value = args.popFirst(), !value.hasPrefix("-") else {
                throw UsageError(message: "--ext needs a value, e.g. --ext cr3")
            }
            extensions += try parseExtensions(value)
        case _ where arg.hasPrefix("--ext="):
            extensions += try parseExtensions(String(arg.dropFirst("--ext=".count)))
        case "--": positional += args; args = []
        case _ where arg.hasPrefix("-") && arg != "-": throw UsageError(message: "unknown option \(arg)")
        default: positional.append(arg)
        }
    }

    guard positional.count == 2 else {
        throw UsageError(message: "expected SOURCE and DEST, got \(positional.count) argument(s)")
    }
    // An empty path would mean the current folder: what an unset shell variable turns into.
    guard !positional.contains("") else { throw UsageError(message: "SOURCE and DEST can't be empty") }

    var options = FlattenOptions(
        source: canonicalPath(positional[0], relativeTo: directory),
        dest: canonicalPath(positional[1], relativeTo: directory)
    )
    options.dryRun = dryRun
    options.prune = prune
    options.skipPairedJPEGs = skipPairedJPEGs
    if !extensions.isEmpty { options.extensions = Set(extensions) }
    return .flatten(options, extensions: extensions)
}

/// The extensions in one --ext value: `cr3`, `.CR3`, or a list such as `cr3,jpg`.
func parseExtensions(_ value: String) throws -> [String] {
    let extensions = value.split(separator: ",", omittingEmptySubsequences: false).map {
        String($0.trimmingPrefix(".")).lowercased()
    }
    let plain = extensions.allSatisfy { ext in
        !ext.isEmpty && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
    guard plain else { throw UsageError(message: "--ext needs an extension such as cr3, got '\(value)'") }
    return extensions
}

/// A file name or message made safe to print. A name can hold any character but `/`, and one from
/// someone else's folder could otherwise move the cursor, recolour or clear the terminal, or break a line
/// to pass for output of its own: control characters are shown escaped, like `\u{1B}`, and so are the
/// ones that reverse the direction of the text that follows them.
func shown(_ text: String) -> String {
    var result = ""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\n": result += "\\n"
        case "\r": result += "\\r"
        case "\t": result += "\\t"
        case _ where scalar.properties.generalCategory == .control || scalar.properties.isBidiControl:
            result += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
        default: result.unicodeScalars.append(scalar)
        }
    }
    return result
}

/// Runs the tool and returns its exit status.
public func run(
    _ arguments: [String],
    version: String,
    directory: String = FileManager.default.currentDirectoryPath,
    out: (String) -> Void = { print($0) },
    err: (String) -> Void = { FileHandle.standardError.write(Data("\($0)\n".utf8)) }
) -> Int32 {
    func usageError(_ message: String) -> Int32 {
        err("\(tool): error: \(shown(message))\nRun '\(tool) --help' for usage.")
        return 64
    }

    let options: FlattenOptions, extensions: [String]
    do {
        switch try parse(arguments, directory: directory) {
        case .help: out(usage); return 0
        case .version: out("\(tool) \(version)"); return 0
        case .flatten(let parsed, let named): (options, extensions) = (parsed, named)
        }
    } catch let error as UsageError {
        return usageError(error.message)
    } catch {
        return usageError(error.localizedDescription)
    }

    for ext in extensions where !ImageTypes.all.contains(ext) {
        err("\(tool): note: .\(ext) is not an image format \(tool) knows; linking it all the same")
    }

    do {
        let summary = try flatten(options) { event in
            switch event {
            case .link(let name): out("link  \(shown(name))")
            case .relink(let name): out("relink \(shown(name))")
            case .prune(let name): out("prune \(shown(name))")
            case .skipPointsElsewhere(let name): err("skip (link exists, points elsewhere): \(shown(name))")
            case .skipRealFile(let name): err("skip (real file in the way): \(shown(name))")
            case .collision(let name, let source, let holder):
                err("skip (link name \(shown(name)) belongs to \(shown(holder))): \(shown(source))")
            case .unreadable(let path, let message): err("unreadable: \(shown(path)): \(shown(message))")
            case .failed(let name, let message): err("failed: \(shown(name)): \(shown(message))")
            }
        }
        if summary.found == 0 {
            let formats = extensions.isEmpty ? "images" : "." + extensions.joined(separator: ", .") + " files"
            err("\(tool): no \(formats) found under \(shown(options.source))")
        }
        let (created, pruned, relinked) = options.dryRun
            ? ("would create", "would prune", "would relink")
            : ("created", "pruned", "relinked")
        var line = "\n\(created) \(summary.created), kept \(summary.kept), skipped \(summary.skipped), \(pruned) \(summary.pruned)"
        if summary.relinked > 0 { line += ", \(relinked) \(summary.relinked)" }
        if options.skipPairedJPEGs { line += ", left out \(summary.paired) paired JPEGs" }
        if summary.failed > 0 { line += ", failed \(summary.failed)" }
        out("\(line)  ->  \(shown(summary.dest))")
        if options.dryRun { out("dry run: nothing was changed") }
        // Success means the link folder shows every image under the source.
        return summary.failed > 0 || summary.skipped > 0 || summary.found == 0 ? 1 : 0
    } catch let error as FlattenError {
        switch error {
        case .sourceNotFolder, .destIsSource: return usageError(error.description)
        case .sourceOnOtherDrive, .destNotFolder, .destNotWritable, .pruneFoundNoImages:
            err("\(tool): error: \(shown(error.description))")
            return 1
        }
    } catch {
        err("\(tool): \(shown(error.localizedDescription))")
        return 1
    }
}
