import Foundation
import Testing
@testable import Workspace
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("Stored path spelling")
struct LocalPathSpellingTests {
    @Test(arguments: [("secret", "SECRET"), ("caf\u{e9}", "cafe\u{301}")])
    func listingOverridesPrimedLookupAliases(stored: String, alias: String) throws {
        // Model a filesystem whose kernel lookup/name cache accepts the alias
        // (and may even report it as the attribute name), while readdir is exact.
        let listing = { [stored] }
        try LocalPathSpelling.checkListing(name: stored, exists: true, creating: false, list: listing)
        #expect(throws: POSIXError(.ENOENT) as NSError) {
            try LocalPathSpelling.checkListing(name: alias, exists: true, creating: false, list: listing)
        }
        #expect(throws: POSIXError(.EEXIST) as NSError) {
            try LocalPathSpelling.checkListing(name: alias, exists: true, creating: true, list: listing)
        }
        do {
            try LocalPathSpelling.checkListing(
                name: alias, exists: true, creating: true, afterCreate: true, list: listing)
            Issue.record("expected a rewritten creation to fail")
        } catch {
            let error = error as NSError
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(EILSEQ))
            #expect(error.localizedDescription.contains("NFD"))
            #expect(error.localizedRecoverySuggestion?.contains("directory listings") == true)
        }
    }

    @Test
    func listingIsFreshEvenWhenDirectoryTimestampsAreUnchanged() throws {
        var names = ["secret"]
        let list = { names }
        try LocalPathSpelling.checkListing(name: "secret", exists: true, creating: false, list: list)
        // FAT-like timestamp granularity cannot be used to reuse the first result.
        names = ["SECRET"]
        #expect(throws: POSIXError(.ENOENT) as NSError) {
            try LocalPathSpelling.checkListing(name: "secret", exists: true, creating: false, list: list)
        }
        try LocalPathSpelling.checkListing(name: "SECRET", exists: true, creating: false, list: list)
        try LocalPathSpelling.checkListing(name: "new", exists: false, creating: true) {
            throw POSIXError(.EACCES) // Missing creations rely on O_EXCL, without enumeration.
        }
    }

    @Test
    func listingPolicyUsesStoredNamesFromRealDirectory() throws {
        let root = try TestSupport.temporaryDirectory("SpellingListing")
        defer { TestSupport.remove(root) }
        let parent = open(root.path, O_RDONLY | O_DIRECTORY)
        #expect(parent >= 0)
        defer { close(parent) }
        let file = openat(parent, "secret", O_CREAT | O_EXCL | O_WRONLY, 0o600)
        #expect(file >= 0)
        close(file)
        // Prime the kernel name cache before checking, if the volume aliases case.
        let alias = openat(parent, "SECRET", O_RDONLY)
        if alias >= 0 { close(alias) }
        let checker = LocalPathSpelling()
        try checker.check(parent: parent, name: "secret", policy: .verifyByListing, creating: false)
        if alias >= 0 {
            #expect(throws: POSIXError(.ENOENT) as NSError) {
                try checker.check(parent: parent, name: "SECRET", policy: .verifyByListing, creating: false)
            }
            #expect(throws: POSIXError(.EEXIST) as NSError) {
                try checker.check(parent: parent, name: "SECRET", policy: .verifyByListing, creating: true)
            }
        }
    }
}
