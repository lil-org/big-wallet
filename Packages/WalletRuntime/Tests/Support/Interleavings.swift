public struct TestScheduleStep: Equatable, Sendable {
    public enum Actor: Equatable, Sendable { case first, second }
    public let actor: Actor
    public let index: Int
}

public func twoActorInterleavings(first: Int, second: Int) -> [[TestScheduleStep]] {
    precondition((1...3).contains(first) && (1...3).contains(second))
    func visit(_ a: Int, _ b: Int, _ prefix: [TestScheduleStep]) -> [[TestScheduleStep]] {
        if a == first && b == second { return [prefix] }
        var result = [[TestScheduleStep]]()
        if a < first { result += visit(a + 1, b, prefix + [TestScheduleStep(actor: .first, index: a)]) }
        if b < second { result += visit(a, b + 1, prefix + [TestScheduleStep(actor: .second, index: b)]) }
        return result
    }
    let result = visit(0, 0, [])
    precondition(result.count <= 20)
    return result
}
