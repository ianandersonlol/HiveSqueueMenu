import Foundation

/// Parses Slurm array task expressions without expanding them into individual task IDs.
///
/// Slurm emits expressions such as `1,3,5-99:2` for a group of array tasks that share
/// one scheduler record. Counting the expression arithmetically keeps large arrays cheap.
enum SlurmArrayExpression {
    static func taskCount(in rawExpression: String) -> Int? {
        var expression = rawExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        if expression.hasPrefix("["), expression.hasSuffix("]") {
            expression.removeFirst()
            expression.removeLast()
        }

        if let throttleSeparator = expression.firstIndex(of: "%") {
            expression = String(expression[..<throttleSeparator])
        }

        guard !expression.isEmpty else { return nil }

        var total = 0
        let components = expression.split(separator: ",", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return nil }

        for rawComponent in components {
            let component = rawComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !component.isEmpty else { return nil }

            let steppedRange = component.split(separator: ":", omittingEmptySubsequences: false)
            guard steppedRange.count <= 2 else { return nil }

            let bounds = steppedRange[0].split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(bounds.count),
                  let lowerBound = nonnegativeInt(bounds[0]) else {
                return nil
            }

            let componentCount: Int
            if bounds.count == 1 {
                guard steppedRange.count == 1 else { return nil }
                componentCount = 1
            } else {
                guard let upperBound = nonnegativeInt(bounds[1]), upperBound >= lowerBound else {
                    return nil
                }

                let step: Int
                if steppedRange.count == 2 {
                    guard let parsedStep = nonnegativeInt(steppedRange[1]), parsedStep > 0 else {
                        return nil
                    }
                    step = parsedStep
                } else {
                    step = 1
                }

                let steppedDistance = (upperBound - lowerBound) / step
                componentCount = steppedDistance == Int.max ? Int.max : steppedDistance + 1
            }

            total = addingWithoutOverflow(total, componentCount)
        }

        return total
    }

    static func taskCount(inJobSelector selector: String) -> Int {
        guard let expression = arrayExpression(inJobSelector: selector),
              let count = taskCount(in: expression) else {
            return 1
        }
        return count
    }

    static func representativeSelector(from selector: String) -> String {
        guard let bracketStart = selector.range(of: "_["), selector.hasSuffix("]") else {
            return selector
        }

        let expressionStart = bracketStart.upperBound
        let expressionEnd = selector.index(before: selector.endIndex)
        let expression = String(selector[expressionStart..<expressionEnd])
        guard let firstComponent = expression.split(separator: ",", maxSplits: 1).first else {
            return selector
        }

        let withoutThrottle = firstComponent.split(separator: "%", maxSplits: 1).first ?? firstComponent
        let withoutStep = withoutThrottle.split(separator: ":", maxSplits: 1).first ?? withoutThrottle
        guard let rawFirstTask = withoutStep.split(separator: "-", maxSplits: 1).first else {
            return selector
        }
        let firstTask = rawFirstTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nonnegativeInt(firstTask) != nil else { return selector }

        return String(selector[..<bracketStart.lowerBound]) + "_" + firstTask
    }

    private static func arrayExpression(inJobSelector selector: String) -> String? {
        guard let bracketStart = selector.range(of: "_["), selector.hasSuffix("]") else {
            return nil
        }
        let expressionEnd = selector.index(before: selector.endIndex)
        return String(selector[bracketStart.upperBound..<expressionEnd])
    }

    private static func nonnegativeInt<S: StringProtocol>(_ rawValue: S) -> Int? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(value), parsed >= 0 else { return nil }
        return parsed
    }

    private static func addingWithoutOverflow(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}
