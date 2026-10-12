import Foundation
import Testing
@testable import TOM

@Suite("RAG stream buffer")
struct RAGStreamBufferTests {

    @Test("Deltas accumulate in order")
    func accumulates() {
        let buffer = RAGStreamBuffer()
        #expect(buffer.append("Hello") == "Hello")
        #expect(buffer.append(", ") == "Hello, ")
        #expect(buffer.append("world") == "Hello, world")
    }

    @Test("Snapshots grow monotonically under concurrent appends")
    func concurrentAppends() async {
        let buffer = RAGStreamBuffer()
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<100 {
                group.addTask { buffer.append("x").count }
            }
            var seen = Set<Int>()
            for await count in group {
                // Every snapshot length is unique — no lost or torn appends.
                #expect(seen.insert(count).inserted)
            }
        }
        #expect(buffer.append("").count == 100)
    }
}
