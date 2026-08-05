import Foundation
import CoreGraphics
import SwiftUI

/// Minimal SVG path-data parser.
///
/// Supports the full command set used by the bundled brand marks —
/// `M L H V C S Q T A Z` in both absolute and relative form — including
/// the compressed forms optimisers emit (implicit line-tos after a
/// move-to, omitted separators before a minus sign, and arc flags packed
/// against the next number).
public enum SVGPath {

    /// Parses `d` attribute data into a `CGPath` in the path's own
    /// coordinate space (y-down, matching SVG).
    public static func cgPath(from data: String) -> CGPath {
        var scanner = Tokenizer(data)
        let path = CGMutablePath()

        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        // Reflection points for the smooth variants of cubic/quadratic.
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var previousCommand: Character?

        while let command = scanner.nextCommand(after: previousCommand) {
            let isRelative = command.isLowercase
            func absolute(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                isRelative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            switch Character(command.lowercased()) {
            case "m":
                guard let x = scanner.number(), let y = scanner.number() else { break }
                current = absolute(x, y)
                subpathStart = current
                path.move(to: current)
                lastCubicControl = nil; lastQuadControl = nil

            case "l":
                guard let x = scanner.number(), let y = scanner.number() else { break }
                current = absolute(x, y)
                path.addLine(to: current)
                lastCubicControl = nil; lastQuadControl = nil

            case "h":
                guard let x = scanner.number() else { break }
                current = isRelative ? CGPoint(x: current.x + x, y: current.y) : CGPoint(x: x, y: current.y)
                path.addLine(to: current)
                lastCubicControl = nil; lastQuadControl = nil

            case "v":
                guard let y = scanner.number() else { break }
                current = isRelative ? CGPoint(x: current.x, y: current.y + y) : CGPoint(x: current.x, y: y)
                path.addLine(to: current)
                lastCubicControl = nil; lastQuadControl = nil

            case "c":
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                      let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { break }
                let c1 = absolute(x1, y1), c2 = absolute(x2, y2)
                current = absolute(x, y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastCubicControl = c2; lastQuadControl = nil

            case "s":
                guard let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { break }
                let c1 = reflect(lastCubicControl, around: current)
                let c2 = absolute(x2, y2)
                current = absolute(x, y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastCubicControl = c2; lastQuadControl = nil

            case "q":
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { break }
                let c = absolute(x1, y1)
                current = absolute(x, y)
                path.addQuadCurve(to: current, control: c)
                lastQuadControl = c; lastCubicControl = nil

            case "t":
                guard let x = scanner.number(), let y = scanner.number() else { break }
                let c = reflect(lastQuadControl, around: current)
                current = absolute(x, y)
                path.addQuadCurve(to: current, control: c)
                lastQuadControl = c; lastCubicControl = nil

            case "a":
                guard let rx = scanner.number(), let ry = scanner.number(),
                      let rotation = scanner.number(),
                      let largeArc = scanner.flag(), let sweep = scanner.flag(),
                      let x = scanner.number(), let y = scanner.number() else { break }
                let end = absolute(x, y)
                appendArc(
                    to: path,
                    from: current,
                    to: end,
                    rx: rx, ry: ry,
                    rotationDegrees: rotation,
                    largeArc: largeArc,
                    sweep: sweep
                )
                current = end
                lastCubicControl = nil; lastQuadControl = nil

            case "z":
                path.closeSubpath()
                current = subpathStart
                lastCubicControl = nil; lastQuadControl = nil

            default:
                break
            }
            previousCommand = command
        }

        return path
    }

    /// Parses `d` and scales it to fill `rect` while preserving aspect ratio,
    /// flipping to SwiftUI's y-down-from-top layout (which already matches SVG,
    /// so this is a pure scale + centre).
    public static func path(from data: String, viewBox: CGSize, in rect: CGRect) -> Path {
        let raw = cgPath(from: data)
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let dx = rect.minX + (rect.width - viewBox.width * scale) / 2
        let dy = rect.minY + (rect.height - viewBox.height * scale) / 2
        var transform = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
        return Path(raw.copy(using: &transform) ?? raw)
    }

    // MARK: - Helpers

    private static func reflect(_ control: CGPoint?, around point: CGPoint) -> CGPoint {
        guard let control else { return point }
        return CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
    }

    /// Endpoint-to-centre arc conversion (SVG spec, appendix F.6), emitted as
    /// cubic segments of at most 90°.
    private static func appendArc(
        to path: CGMutablePath,
        from start: CGPoint,
        to end: CGPoint,
        rx: CGFloat,
        ry: CGFloat,
        rotationDegrees: CGFloat,
        largeArc: Bool,
        sweep: Bool
    ) {
        // Degenerate radii collapse the arc to a line, per spec.
        var rx = abs(rx), ry = abs(ry)
        if rx == 0 || ry == 0 || (start.x == end.x && start.y == end.y) {
            path.addLine(to: end)
            return
        }

        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        let dx2 = (start.x - end.x) / 2, dy2 = (start.y - end.y) / 2
        let x1p =  cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        // Scale up radii that are too small to span the endpoints.
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda)
            rx *= s; ry *= s
        }

        let sign: CGFloat = (largeArc != sweep) ? 1 : -1
        let numerator = max(0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let coefficient = denominator == 0 ? 0 : sign * sqrt(numerator / denominator)

        let cxp =  coefficient * rx * y1p / ry
        let cyp = -coefficient * ry * x1p / rx

        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            guard len > 0 else { return 0 }
            let a = acos(min(1, max(-1, dot / len)))
            return (ux * vy - uy * vx < 0) ? -a : a
        }

        let startAngle = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var sweepAngle = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && sweepAngle > 0 { sweepAngle -= 2 * .pi }
        if sweep && sweepAngle < 0 { sweepAngle += 2 * .pi }

        let segments = max(1, Int(ceil(abs(sweepAngle) / (.pi / 2))))
        let delta = sweepAngle / CGFloat(segments)
        // Magic constant for approximating a circular arc with a cubic.
        let alpha = 4.0 / 3.0 * tan(delta / 4)

        var theta = startAngle
        for _ in 0..<segments {
            let theta2 = theta + delta
            let cosT1 = cos(theta), sinT1 = sin(theta)
            let cosT2 = cos(theta2), sinT2 = sin(theta2)

            func point(_ c: CGFloat, _ s: CGFloat) -> CGPoint {
                CGPoint(
                    x: cx + rx * cosPhi * c - ry * sinPhi * s,
                    y: cy + rx * sinPhi * c + ry * cosPhi * s
                )
            }
            func derivative(_ c: CGFloat, _ s: CGFloat) -> CGPoint {
                CGPoint(
                    x: -rx * cosPhi * s - ry * sinPhi * c,
                    y: -rx * sinPhi * s + ry * cosPhi * c
                )
            }

            let p2 = point(cosT2, sinT2)
            let d1 = derivative(cosT1, sinT1)
            let d2 = derivative(cosT2, sinT2)
            let p1 = point(cosT1, sinT1)

            path.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + alpha * d1.x, y: p1.y + alpha * d1.y),
                control2: CGPoint(x: p2.x - alpha * d2.x, y: p2.y - alpha * d2.y)
            )
            theta = theta2
        }
    }

    // MARK: - Tokenizer

    private struct Tokenizer {
        private let chars: [Character]
        private var index: Int = 0

        init(_ string: String) {
            self.chars = Array(string)
        }

        private mutating func skipSeparators() {
            while index < chars.count, chars[index] == " " || chars[index] == ","
                    || chars[index] == "\n" || chars[index] == "\t" || chars[index] == "\r" {
                index += 1
            }
        }

        /// Returns the next explicit command letter, or repeats `previous`
        /// when the data continues with more coordinates (implicit repeat).
        /// Per the spec a repeated `M`/`m` becomes an implicit line-to.
        mutating func nextCommand(after previous: Character?) -> Character? {
            skipSeparators()
            guard index < chars.count else { return nil }
            let c = chars[index]
            if c.isLetter {
                index += 1
                return c
            }
            guard let previous else { return nil }
            switch previous {
            case "M": return "L"
            case "m": return "l"
            default:  return previous
            }
        }

        /// Scans one number, tolerating omitted separators (`-.5.5`) and
        /// scientific notation.
        mutating func number() -> CGFloat? {
            skipSeparators()
            guard index < chars.count else { return nil }
            let start = index

            if chars[index] == "+" || chars[index] == "-" { index += 1 }
            var sawDigit = false
            while index < chars.count, chars[index].isNumber { index += 1; sawDigit = true }
            if index < chars.count, chars[index] == "." {
                index += 1
                while index < chars.count, chars[index].isNumber { index += 1; sawDigit = true }
            }
            guard sawDigit else { index = start; return nil }
            if index < chars.count, chars[index] == "e" || chars[index] == "E" {
                let exponentStart = index
                index += 1
                if index < chars.count, chars[index] == "+" || chars[index] == "-" { index += 1 }
                var sawExponentDigit = false
                while index < chars.count, chars[index].isNumber { index += 1; sawExponentDigit = true }
                if !sawExponentDigit { index = exponentStart }
            }

            guard let value = Double(String(chars[start..<index])) else { return nil }
            return CGFloat(value)
        }

        /// Arc flags are a single character and may be packed directly against
        /// the number that follows (`a1 1 0 011.5 0`), so they can't go through
        /// the general number scanner.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < chars.count else { return nil }
            switch chars[index] {
            case "0": index += 1; return false
            case "1": index += 1; return true
            default:  return nil
            }
        }
    }
}

/// A `Shape` backed by SVG path data, scaled to fit its frame.
public struct SVGShape: Shape {
    public let pathData: String
    public let viewBox: CGSize

    public init(pathData: String, viewBox: CGSize) {
        self.pathData = pathData
        self.viewBox = viewBox
    }

    public func path(in rect: CGRect) -> Path {
        SVGPath.path(from: pathData, viewBox: viewBox, in: rect)
    }
}
