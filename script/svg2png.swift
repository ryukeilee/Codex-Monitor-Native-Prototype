import AppKit
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: svg2png <input.svg> <output.png>")
    exit(1)
}

let inputPath = args[1]
let outputPath = args[2]

guard let image = NSImage(contentsOfFile: inputPath) else {
    print("error: failed to load SVG from \(inputPath)")
    exit(1)
}

guard let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData) else {
    print("error: failed to get bitmap representation")
    exit(1)
}

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    print("error: failed to encode PNG")
    exit(1)
}

do {
    try pngData.write(to: URL(fileURLWithPath: outputPath))
    print("ok: \(outputPath)")
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
