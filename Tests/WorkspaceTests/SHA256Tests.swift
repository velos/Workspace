import Foundation
import Testing
@testable import Workspace

@Suite("SHA256")
struct SHA256Tests {
    @Test
    func `digest matches FIPS 180-4 test vectors`() {
        #expect(
            SHA256.hexDigest(of: Data())
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        #expect(
            SHA256.hexDigest(of: Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        #expect(
            SHA256.hexDigest(of: Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
        #expect(
            SHA256.hexDigest(of: Data("hello world".utf8))
                == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
        )
    }

    @Test
    func `digest handles multi-block and block-boundary inputs`() {
        // 55, 56, and 64 bytes cross the padding boundaries; 1000 bytes spans many blocks.
        let a55 = Data(String(repeating: "a", count: 55).utf8)
        let a56 = Data(String(repeating: "a", count: 56).utf8)
        let a64 = Data(String(repeating: "a", count: 64).utf8)
        let a1000 = Data(String(repeating: "a", count: 1000).utf8)

        #expect(SHA256.hexDigest(of: a55) == "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
        #expect(SHA256.hexDigest(of: a56) == "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
        #expect(SHA256.hexDigest(of: a64) == "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
        #expect(SHA256.hexDigest(of: a1000) == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }
}
