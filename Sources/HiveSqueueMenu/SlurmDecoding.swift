import Foundation

struct SlurmResponse: Decodable {
    let jobs: [SlurmJob]
}

struct SlurmTimeInfo: Decodable {
    let elapsedSeconds: Int?
    let startEpoch: Int?
    let limitSeconds: Int?
    let isLimitInfinite: Bool
    let rawElapsedDescription: String?

    private enum CodingKeys: String, CodingKey {
        case elapsed
        case start
        case limit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let stringValue = try? container.decodeIfPresent(String.self, forKey: .elapsed) {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            rawElapsedDescription = trimmed.isEmpty ? nil : trimmed
            if let parsedInt = Int(trimmed) {
                elapsedSeconds = parsedInt
            } else if let duration = SlurmJob.seconds(fromTimeString: trimmed) {
                elapsedSeconds = duration
            } else {
                elapsedSeconds = nil
            }
        } else if let wrapper = try? container.decodeIfPresent(SlurmNumber.self, forKey: .elapsed),
                  let numeric = wrapper.optionalValue {
            elapsedSeconds = numeric
            rawElapsedDescription = nil
        } else if let intValue = try? container.decodeIfPresent(Int.self, forKey: .elapsed) {
            elapsedSeconds = intValue
            rawElapsedDescription = nil
        } else {
            elapsedSeconds = nil
            rawElapsedDescription = nil
        }

        startEpoch = SlurmTimeInfo.decodeFlexibleInt(container, key: .start)

        if let wrapper = try? container.decode(SlurmNumber.self, forKey: .limit) {
            if let minutes = wrapper.optionalValue {
                limitSeconds = minutes * 60
            } else {
                limitSeconds = nil
            }
            isLimitInfinite = wrapper.infinite
        } else if let limitValue = try? container.decodeIfPresent(Int.self, forKey: .limit) {
            limitSeconds = limitValue * 60
            isLimitInfinite = false
        } else if let limitString = try? container.decodeIfPresent(String.self, forKey: .limit),
                  let seconds = SlurmJob.seconds(fromTimeString: limitString) {
            limitSeconds = seconds
            isLimitInfinite = false
        } else {
            limitSeconds = nil
            isLimitInfinite = false
        }
    }
}

private extension SlurmTimeInfo {
    private static func decodeFlexibleInt(_ container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let raw = try? container.decodeIfPresent(String.self, forKey: key) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = Int(trimmed) {
                return parsed
            }
            if let seconds = SlurmJob.seconds(fromTimeString: trimmed) {
                return seconds
            }
        }
        if let wrapper = try? container.decodeIfPresent(SlurmNumber.self, forKey: key) {
            return wrapper.optionalValue
        }
        return nil
    }
}

extension KeyedDecodingContainer where Key: CodingKey {
    func decodeSafely<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    func decodeNumericValue(forKey key: Key) -> Int? {
        if let wrapped: SlurmNumber = decodeSafely(SlurmNumber.self, forKey: key),
           let numeric = wrapped.optionalValue {
            return numeric
        }

        if let intValue: Int = decodeSafely(Int.self, forKey: key) {
            return intValue
        }

        if let stringValue: String = decodeSafely(String.self, forKey: key) {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let intValue = Int(trimmed) {
                return intValue
            }
            if let doubleValue = Double(trimmed) {
                return Int(doubleValue)
            }
        }

        if let doubleValue: Double = decodeSafely(Double.self, forKey: key) {
            return Int(doubleValue)
        }

        if let boolValue: Bool = decodeSafely(Bool.self, forKey: key) {
            return boolValue ? 1 : 0
        }

        return nil
    }

    func decodeSlurmInt(forKey key: Key) -> Int {
        decodeNumericValue(forKey: key) ?? 0
    }

    func decodeSlurmOptionalInt(forKey key: Key) -> Int? {
        decodeNumericValue(forKey: key)
    }

    func decodeSlurmDurationSeconds(forKey key: Key) -> Int? {
        if let wrapped: SlurmNumber = decodeSafely(SlurmNumber.self, forKey: key),
           let value = wrapped.optionalValue {
            return value * 60
        }

        if let intValue: Int = decodeSafely(Int.self, forKey: key) {
            return intValue * 60
        }

        if let stringValue: String = decodeSafely(String.self, forKey: key) {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let intValue = Int(trimmed) {
                return intValue * 60
            }
            if let seconds = SlurmJob.seconds(fromTimeString: trimmed) {
                return seconds
            }
        }

        return nil
    }

    func decodeSlurmString(forKey key: Key) -> String {
        if let wrapped: SlurmString = decodeSafely(SlurmString.self, forKey: key) {
            return wrapped.value
        }

        if let stringValue: String = decodeSafely(String.self, forKey: key) {
            return stringValue
        }

        if let intValue: Int = decodeSafely(Int.self, forKey: key) {
            return String(intValue)
        }

        if let doubleValue: Double = decodeSafely(Double.self, forKey: key) {
            return String(doubleValue)
        }

        if let boolValue: Bool = decodeSafely(Bool.self, forKey: key) {
            return boolValue ? "true" : "false"
        }

        return ""
    }

    func decodeSlurmOptionalString(forKey key: Key) -> String? {
        if let wrapped: SlurmString = decodeSafely(SlurmString.self, forKey: key),
           let value = wrapped.optionalValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }

        if let stringValue: String = decodeSafely(String.self, forKey: key) {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let intValue: Int = decodeSafely(Int.self, forKey: key) {
            return String(intValue)
        }

        if let doubleValue: Double = decodeSafely(Double.self, forKey: key) {
            return String(doubleValue)
        }

        if let boolValue: Bool = decodeSafely(Bool.self, forKey: key) {
            return boolValue ? "true" : "false"
        }

        return nil
    }

    func decodeSlurmStateArray(forKey key: Key) -> [String] {
        if let stringArray = try? decodeIfPresent([String].self, forKey: key) {
            let trimmed = stringArray
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        if let wrappedArray = try? decodeIfPresent([SlurmString].self, forKey: key) {
            let values = wrappedArray
                .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !values.isEmpty {
                return values
            }
        }

        let single = decodeSlurmString(forKey: key).trimmingCharacters(in: .whitespacesAndNewlines)
        if !single.isEmpty {
            return [single]
        }

        return []
    }
}
