import Foundation

// Slurm wraps numeric values in a structure with set/infinite/number fields
struct SlurmNumber: Decodable {
    let set: Bool
    let infinite: Bool
    private let rawNumber: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        set = (try? container.decode(Bool.self, forKey: .set)) ?? false
        infinite = (try? container.decode(Bool.self, forKey: .infinite)) ?? false

        if let intValue = try? container.decode(Int.self, forKey: .number) {
            rawNumber = intValue
        } else if let doubleValue = try? container.decode(Double.self, forKey: .number) {
            rawNumber = Int(doubleValue)
        } else if let stringValue = try? container.decode(String.self, forKey: .number) {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let intValue = Int(trimmed) {
                rawNumber = intValue
            } else if let doubleValue = Double(trimmed) {
                rawNumber = Int(doubleValue)
            } else {
                rawNumber = nil
            }
        } else {
            rawNumber = nil
        }
    }

    var value: Int {
        rawNumber ?? 0
    }

    var optionalValue: Int? {
        guard !infinite else { return nil }
        return rawNumber
    }

    private enum CodingKeys: String, CodingKey {
        case set
        case infinite
        case number
    }
}

// Slurm wraps string values similarly
struct SlurmString: Decodable {
    let set: Bool
    let infinite: Bool
    private let rawValue: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        set = (try? container.decode(Bool.self, forKey: .set)) ?? false
        infinite = (try? container.decode(Bool.self, forKey: .infinite)) ?? false

        if let stringValue = try? container.decode(String.self, forKey: .string) {
            rawValue = stringValue
            return
        }

        if let stringValue = try? container.decode(String.self, forKey: .number) {
            rawValue = stringValue
            return
        }

        if let intValue = try? container.decode(Int.self, forKey: .number) {
            rawValue = String(intValue)
            return
        }

        if let doubleValue = try? container.decode(Double.self, forKey: .number) {
            rawValue = String(doubleValue)
            return
        }

        if let boolValue = try? container.decode(Bool.self, forKey: .number) {
            rawValue = boolValue ? "true" : "false"
            return
        }

        rawValue = nil
    }

    var value: String {
        rawValue ?? ""
    }

    var optionalValue: String? {
        rawValue
    }

    private enum CodingKeys: String, CodingKey {
        case set
        case infinite
        case number
        case string
    }
}
