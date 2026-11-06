internal import Crypto
import Foundation
internal import HangarSupport
internal import NIOSSL
internal import SwiftASN1
internal import X509

/// A VM's own certificate authority, which the guest trusts so the secrets proxy can open its HTTPS to hosts with a
/// secret. The guest trusts its root once; the root signs an intermediate whose name constraints allow exactly the
/// hosts with a secret, and only the intermediate signs the certificates the proxy shows. A new host set gets a new
/// intermediate and no new root, since macOS asks a person before it trusts a root. The keys stay in the Mac's
/// Keychain; only the root's certificate goes to the guest.
package final class SecretAuthority: Sendable {
    struct Stored: Codable {
        let rootKey: String
        let root: Data
        let intermediateKey: String
        let intermediate: Data
        let hosts: [String]
    }

    private struct Issuer {
        let certificate: Certificate
        let key: P256.Signing.PrivateKey

        var keyIdentifier: ArraySlice<UInt8> {
            SubjectKeyIdentifier(hash: .init(key.publicKey)).keyIdentifier
        }
    }

    static let rootLifetime: TimeInterval = 10 * 365 * 24 * 3600
    static let leafLifetime: TimeInterval = 7 * 24 * 3600
    /// A certificate the proxy made is used for this long, a small part of its lifetime.
    static let leafReuse: TimeInterval = 24 * 3600
    /// Clocks in guests are often a little behind.
    static let backdating: TimeInterval = 24 * 3600

    /// What the guest trusts.
    package let certificateDER: [UInt8]
    private let intermediate: Issuer
    private let intermediateDER: [UInt8]

    private init(root: Certificate, intermediate: Issuer) throws {
        certificateDER = try Self.der(root)
        self.intermediate = intermediate
        intermediateDER = try Self.der(intermediate.certificate)
    }

    /// The vault's authority for `hosts`: its root as before, and a new intermediate when the hosts changed.
    package static func load(vault: String, hosts: Set<String>) throws -> SecretAuthority {
        let sortedHosts = hosts.sorted()
        let stored = try storedIfAny(vault)
        let root = try stored.map(rootIssuer) ?? newRoot(vault: vault)

        if let stored, stored.hosts == sortedHosts {
            let key = try P256.Signing.PrivateKey(pemRepresentation: stored.intermediateKey)
            let certificate = try Certificate(derEncoded: Array(stored.intermediate))
            return try SecretAuthority(root: root.certificate, intermediate: Issuer(certificate: certificate, key: key))
        }

        let intermediate = try newIntermediate(vault: vault, hosts: sortedHosts, root: root)
        try save(
            Stored(
                rootKey: root.key.pemRepresentation, root: Data(try der(root.certificate)),
                intermediateKey: intermediate.key.pemRepresentation,
                intermediate: Data(try der(intermediate.certificate)), hosts: sortedHosts),
            vault: vault)
        return try SecretAuthority(root: root.certificate, intermediate: intermediate)
    }

    package static func isFresh(madeAt: Date, now: Date) -> Bool {
        now >= madeAt && now.timeIntervalSince(madeAt) < leafReuse
    }

    package static func delete(vault: String) throws {
        try Keychain.delete(account(vault))
    }

    /// The TLS identity the proxy shows the guest for `host`: a short-lived certificate the intermediate signs, sent
    /// with the intermediate.
    func toGuestContext(for host: String, speaking applicationProtocol: ApplicationProtocol, now: Date = Date())
        throws -> NIOSSLContext
    {
        let leafKey = P256.Signing.PrivateKey()
        let leaf = try leafCertificate(for: host, key: leafKey, now: now)

        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [
                .certificate(try NIOSSLCertificate(bytes: try Self.der(leaf), format: .der)),
                .certificate(try NIOSSLCertificate(bytes: intermediateDER, format: .der)),
            ],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(leafKey.pemRepresentation.utf8), format: .pem)))
        configuration.minimumTLSVersion = .tlsv12
        configuration.applicationProtocols = [applicationProtocol.rawValue]
        return try NIOSSLContext(configuration: configuration)
    }

    /// The key identifiers are what strict verifiers, like Python's, use to build the chain.
    private func leafCertificate(for host: String, key: P256.Signing.PrivateKey, now: Date) throws -> Certificate {
        try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: .init(key.publicKey),
            notValidBefore: now - Self.backdating, notValidAfter: now + Self.leafLifetime,
            issuer: intermediate.certificate.subject, subject: try DistinguishedName { CommonName(host) },
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([.dnsName(host)])
                SubjectKeyIdentifier(hash: .init(key.publicKey))
                AuthorityKeyIdentifier(keyIdentifier: intermediate.keyIdentifier)
            },
            issuerPrivateKey: .init(intermediate.key))
    }

    private static func newRoot(vault: String, now: Date = Date()) throws -> Issuer {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName {
            CommonName("Hangar \(vault.prefix(8))")
            OrganizationName("Hangar")
        }
        let certificate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: .init(key.publicKey),
            notValidBefore: now - backdating, notValidAfter: now + rootLifetime, issuer: name, subject: name,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 1))
                Critical(KeyUsage(keyCertSign: true))
                SubjectKeyIdentifier(hash: .init(key.publicKey))
            },
            issuerPrivateKey: .init(key))
        return Issuer(certificate: certificate, key: key)
    }

    private static func newIntermediate(vault: String, hosts: [String], root: Issuer, now: Date = Date()) throws
        -> Issuer
    {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName {
            CommonName("Hangar \(vault.prefix(8)) hosts")
            OrganizationName("Hangar")
        }
        let certificate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: .init(key.publicKey),
            notValidBefore: now - backdating, notValidAfter: root.certificate.notValidAfter,
            issuer: root.certificate.subject, subject: name,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true))
                Critical(NameConstraints(permittedDNSDomains: hosts))
                SubjectKeyIdentifier(hash: .init(key.publicKey))
                AuthorityKeyIdentifier(keyIdentifier: root.keyIdentifier)
            },
            issuerPrivateKey: .init(root.key))
        return Issuer(certificate: certificate, key: key)
    }

    private static func rootIssuer(_ stored: Stored) throws -> Issuer {
        Issuer(
            certificate: try Certificate(derEncoded: Array(stored.root)),
            key: try P256.Signing.PrivateKey(pemRepresentation: stored.rootKey))
    }

    private static func der(_ certificate: Certificate) throws -> [UInt8] {
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return serializer.serializedBytes
    }

    /// A Keychain that fails for another reason, like a locked one, and a damaged record are both errors: a new root
    /// would need the guest's trust again, and the old one would stay trusted.
    private static func storedIfAny(_ vault: String) throws -> Stored? {
        let text: String
        do {
            text = try Keychain.read(account(vault))
        } catch is Keychain.Missing {
            return nil
        }
        return try stored(from: text)
    }

    static func stored(from text: String) throws -> Stored {
        do {
            return try JSONDecoder().decode(Stored.self, from: Data(text.utf8))
        } catch {
            throw HangarError(
                "Hangar's certificate authority for this VM in your Keychain can't be read (\(error)). "
                    + "Remove the VM's secrets and add them again.")
        }
    }

    private static func save(_ stored: Stored, vault: String) throws {
        let text = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
        try Keychain.save(text, for: account(vault), label: "Hangar certificate authority of a VM")
    }

    private static func account(_ vault: String) -> String {
        "secret-authority.\(vault)"
    }
}
