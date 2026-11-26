// swift Tools/verify-release-feed.swift <appcast.xml> <archive.zip> <version>
import CryptoKit
import Foundation

enum InvalidFeed: Error { case metadata, signature }
let arguments = CommandLine.arguments
guard arguments.count == 4 else { throw InvalidFeed.metadata }
let version = arguments[3]
let xml = try XMLDocument(contentsOf: URL(fileURLWithPath: arguments[1]))
let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[2]), options: .mappedIfSafe)
let sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
let url = "https://github.com/paulpeef/salary-flow/releases/download/v\(version)/SalaryFlow-\(version).zip"
guard let item = try xml.nodes(forXPath: "/rss/channel/item").first as? XMLElement,
      item.elements(forLocalName: "version", uri: sparkle).first?.stringValue == version,
      let file = item.elements(forName: "enclosure").first,
      file.attribute(forName: "url")?.stringValue == url,
      file.attribute(forName: "length")?.stringValue == String(archive.count),
      let value = file.attribute(forLocalName: "edSignature", uri: sparkle)?.stringValue,
      let signature = Data(base64Encoded: value) else { throw InvalidFeed.metadata }
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: "oHSDimtXW5KkFmck6f786b9x//NPa6Zgat0oSw0qzOE=")!)
guard key.isValidSignature(signature, for: archive) else { throw InvalidFeed.signature }
print("Verified Sparkle signature for \(version) (\(archive.count) bytes).")
