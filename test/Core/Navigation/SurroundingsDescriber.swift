//
//  SurroundingsDescriber.swift
//  test
//
//  The on-demand spoken summary ("Describe surroundings"): what is ahead, and how
//  far it is open to the left and right, using the map's memory so directions the
//  user already panned past are included. Unmapped space is said to be unmapped.
//

nonisolated enum SurroundingsDescriber {

    static func describe(sensing: SensingStatus, assessment: PathAssessment?, aheadLabel: String?) -> String {
        guard sensing == .ok else { return sensing.spokenWarning }
        guard let assessment else { return "Not mapped yet. Turn slowly left and right." }

        var parts: [String] = []
        if let obstacle = assessment.ahead {
            parts.append("\(AlertPolicy.name(of: obstacle, label: aheadLabel)) ahead, \(AlertPolicy.distancePhrase(obstacle.distance))")
        } else if let ahead = opening(assessment, 0) {
            parts.append(phrase(ahead, side: "Ahead"))
        }
        let sides = [("Left", opening(assessment, -40)), ("Right", opening(assessment, 40))]
        for (side, o) in sides {
            if let o { parts.append(phrase(o, side: side)) }
        }

        let unmapped = [opening(assessment, -40), opening(assessment, 0), opening(assessment, 40)]
            .compactMap { $0 }
            .filter { $0.end == .unexplored && $0.freeMeters < 1 }
            .count
        var sentence = parts.joined(separator: ". ") + "."
        if unmapped >= 2 { sentence += " Turn slowly left and right to map more." }
        return sentence
    }

    static func phrase(_ o: Opening, side: String) -> String {
        switch o.end {
        case .clear:
            return "\(side): open for at least \(AlertPolicy.distancePhrase(o.freeMeters))"
        case .obstacle:
            return o.freeMeters < 0.3 ? "\(side): blocked close by"
                                      : "\(side): blocked after \(AlertPolicy.distancePhrase(o.freeMeters))"
        case .unexplored:
            return o.freeMeters < 1 ? "\(side): not mapped yet"
                                    : "\(side): open for \(AlertPolicy.distancePhrase(o.freeMeters)), not mapped beyond"
        }
    }

    private static func opening(_ a: PathAssessment, _ bearing: Float) -> Opening? {
        a.openings.first { $0.bearingDegrees == bearing }
    }
}
