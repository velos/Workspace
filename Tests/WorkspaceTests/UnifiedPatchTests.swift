import Testing
@testable import Workspace

@Suite("Unified patch")
struct UnifiedPatchTests {
    @Test
    func `text diff renders standard headers hunks and newline markers`() {
        let diff = TextDiff.lineBased(from: "hello world", to: "hello Swift")

        #expect(
            diff.unifiedPatch(oldPath: "a/note.txt", newPath: "b/note.txt") == """
            --- a/note.txt
            +++ b/note.txt
            @@ -1 +1 @@
            -hello world
            \\ No newline at end of file
            +hello Swift
            \\ No newline at end of file

            """
        )
    }

    @Test
    func `changeset uses dev null for file creation and deletion`() {
        let created = TextDiff.lineBased(from: "", to: "new\n")
        let deleted = TextDiff.lineBased(from: "old\n", to: "")
        let changes = ChangeSet(changes: [
            .init(path: "/created.txt", kind: .file, effect: .created, diff: created),
            .init(path: "/deleted.txt", kind: .file, effect: .deleted, diff: deleted),
            .init(path: "/binary.dat", kind: .file, effect: .modified),
        ])

        let patch = changes.unifiedPatch()
        #expect(patch.contains("--- /dev/null\n+++ b/created.txt\n@@ -0,0 +1 @@\n+new\n"))
        #expect(patch.contains("--- a/deleted.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\n"))
        #expect(!patch.contains("binary.dat"))
    }

    @Test
    func `CRLF patch preserves bytes with accurate hunk counts and EOF marker`() {
        let diff = TextDiff.lineBased(from: "one\r\ntwo\r\nlast", to: "one\r\nTWO\r\nlast\r\n")
        #expect(diff.unifiedPatch(oldPath: "a/note", newPath: "b/note") ==
            "--- a/note\n+++ b/note\n@@ -1,3 +1,3 @@\n one\r\n-two\r\n-last\n\\ No newline at end of file\n+TWO\r\n+last\r\n")
    }
}
