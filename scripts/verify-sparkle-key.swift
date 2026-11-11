// Checks that a Sparkle EdDSA signature belongs to the public key the app ships with.
//
//   swift scripts/verify-sparkle-key.swift <public key, base64> <file> <signature, base64>
//
// Exit status 0: the signature is valid for that public key; 1: it is not; 2: wrong arguments.
// Used by scripts/release.sh: it signs a probe file with the release signing key and verifies the
// result against the SUPublicEDKey of the built app, so a swapped or mistyped key stops the release
// before anything is published.
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4,
      let publicRaw = Data(base64Encoded: arguments[1].trimmingCharacters(in: .whitespacesAndNewlines)),
      let signature = Data(base64Encoded: arguments[3].trimmingCharacters(in: .whitespacesAndNewlines)),
      let message = FileManager.default.contents(atPath: arguments[2]) else {
    FileHandle.standardError.write(Data("Aufruf: verify-sparkle-key.swift <öffentlicher Schlüssel> <Datei> <Signatur>\n".utf8))
    exit(2)
}
guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicRaw) else {
    FileHandle.standardError.write(Data("Der öffentliche Schlüssel ist kein gültiger Ed25519-Schlüssel.\n".utf8))
    exit(1)
}
exit(key.isValidSignature(signature, for: message) ? 0 : 1)
