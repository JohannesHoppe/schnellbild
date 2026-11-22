// Writes the sample files of the formats the app decodes itself (QOI, PCX,
// DCX) and the RAW files the tests give LibRaw, made from the visual checks'
// reference picture (Tests/SchnellbildTests/ReferencePicture.swift, encoded
// by DecoderFixtures.swift): the same bytes the unit tests make. Built and run by Scripts/make_decoder_samples.sh.
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/decoder-samples")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
func write(_ name: String, _ data: Data) throws {
    try data.write(to: folder.appendingPathComponent(name))
    print("\(name): \(data.count) bytes")
}

let reference = DecoderFixtures.reference()
let withAlpha = DecoderFixtures.reference(alpha: true)
try write("reference.png", reference.png)
try write("reference-alpha.png", withAlpha.png)
try write("rgb.qoi", DecoderFixtures.qoi(reference, channels: 3))
try write("rgba.qoi", DecoderFixtures.qoi(withAlpha, channels: 4))
for kind in DecoderFixtures.PCXKind.allCases {
    let pcx = DecoderFixtures.pcx(kind == .rgba ? withAlpha : reference, kind: kind)
    try write("\(kind.rawValue).pcx", pcx.data)
    try write("\(kind.rawValue)-expected.png", pcx.expected.png)
}
try write("pages.dcx", DecoderFixtures.dcx([DecoderFixtures.pcx(reference, kind: .rgb).data, DecoderFixtures.pcx(reference, kind: .mono).data]))
try write("casio-qv2000ux.bay", DecoderFixtures.casioBay(reference))
try write("camera.dng", DecoderFixtures.dng(reference, preview: true))
