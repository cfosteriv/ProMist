// Reusable oscillation arc/preset visualization and controls. Geometry converts
// logical -3...3 presets into a fan-relative display without owning device state.
import SwiftUI

struct OscillationControl: View {
    private struct Piece {
        let startDegrees: Double
        let endDegrees: Double
        let requiredMode: UInt8
        let preset: Int8
    }

    private static let pieces = [
        Piece(startDegrees: 180, endDegrees: 150, requiredMode: 3, preset: 3),
        Piece(startDegrees: 150, endDegrees: 120, requiredMode: 2, preset: 2),
        Piece(startDegrees: 120, endDegrees: 90, requiredMode: 1, preset: 1),
        Piece(startDegrees: 90, endDegrees: 60, requiredMode: 1, preset: -1),
        Piece(startDegrees: 60, endDegrees: 30, requiredMode: 2, preset: -2),
        Piece(startDegrees: 30, endDegrees: 0, requiredMode: 3, preset: -3)
    ]

    let mode: UInt8
    let facingPreset: Int8
    let destinationPreset: Int8?
    let canPosition: Bool
    let selectMode: (UInt8) -> Void
    let moveToPreset: (Int8) -> Void
    let jogClockwise: () -> Void
    let jogCounterClockwise: () -> Void
    let home: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            
            HStack (alignment: .top) {
                Text("Direction")
                Spacer()
                if canPosition {
                    Button(action: home) {
                        Image(systemName: "arrowshape.up.circle")
                    }
                    .proMistGlassButton(prominent: true)
                    .accessibilityLabel("Return to home position")
                }
            }

            GeometryReader { proxy in
                Canvas { context, size in
                    drawArc(context: &context, size: size)
                }
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture(count: 2)
                        .exclusively(before: SpatialTapGesture(count: 1))
                        .onEnded { result in
                            switch result {
                            case .first(let doubleTap):
                                moveToPiece(
                                    at: doubleTap.location,
                                    size: proxy.size
                                )
                            case .second(let singleTap):
                                selectPiece(
                                    at: singleTap.location,
                                    size: proxy.size
                                )
                            }
                        }
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Direction and range")
                .accessibilityValue(modeLabel)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment:
                        selectMode(min(mode + 1, 3))
                    case .decrement:
                        selectMode(mode > 0 ? mode - 1 : 0)
                    @unknown default:
                        break
                    }
                }
            }
            .aspectRatio(4 / 1.15, contentMode: .fit)

            if canPosition {
                HStack {
                    Button(action: jogClockwise) {
                        Image(systemName: "arrow.left")
                            .frame(width: 44, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Jog clockwise")

                    Spacer()

                    Button(action: jogCounterClockwise) {
                        Image(systemName: "arrow.right")
                            .frame(width: 44, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Jog counterclockwise")
                }
                .disabled(facingPreset == -128)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("oscillation-position-controls")
            }
        }
        .padding(.vertical, 4)
    }

    private var modeLabel: String {
        switch mode {
        case 1: "45 degrees"
        case 2: "90 degrees"
        case 3: "180 degrees"
        default: "Off"
        }
    }

    private var facingPieceIndex: Int? {
        pieceIndex(for: facingPreset)
    }

    private var destinationPieceIndex: Int? {
        guard let destinationPreset else { return nil }
        return pieceIndex(for: destinationPreset)
    }

    private func pieceIndex(for preset: Int8) -> Int? {
        switch preset {
        case 3: 0
        case 2: 1
        case 1: 2
        case -1: 3
        case -2: 4
        case -3: 5
        default: nil
        }
    }

    private func drawArc(context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height - 4)
        let horizontalRadius = size.width / 2 - 6
        let verticalRadius = size.height - 8

        for (index, piece) in Self.pieces.enumerated() {
            let path = wedgePath(
                center: center,
                horizontalRadius: horizontalRadius,
                verticalRadius: verticalRadius,
                startDegrees: piece.startDegrees,
                endDegrees: piece.endDegrees
            )
            let isFacing = mode == 0 && facingPieceIndex == index
            let isDestination = destinationPieceIndex == index
            let isSelected = mode >= piece.requiredMode
            let fill: Color = if isDestination {
                Color(red: 0, green: 0, blue: 0.68)
            } else if isFacing {
                .accentColor.opacity(0.78)
            } else if isSelected {
                .accentColor.opacity(0.28)
            } else {
                .secondary.opacity(0.10)
            }
            context.fill(path, with: .color(fill))
            context.stroke(
                path,
                with: .color(.primary.opacity(0.20)),
                lineWidth: 1
            )

        }
    }

    private func selectPiece(at location: CGPoint, size: CGSize) {
        guard let piece = piece(at: location, size: size) else { return }
        selectMode(piece.requiredMode)
    }

    private func moveToPiece(at location: CGPoint, size: CGSize) {
        guard canPosition else { return }
        guard let piece = piece(at: location, size: size) else { return }
        moveToPreset(piece.preset)
    }

    private func piece(at location: CGPoint, size: CGSize) -> Piece? {
        let center = CGPoint(x: size.width / 2, y: size.height - 4)
        let horizontalRadius = size.width / 2 - 6
        let verticalRadius = size.height - 8
        let deltaX = location.x - center.x
        let deltaY = center.y - location.y
        let normalizedX = deltaX / horizontalRadius
        let normalizedY = deltaY / verticalRadius
        let distance = hypot(normalizedX, normalizedY)
        guard deltaY >= 0, distance <= 1 else { return nil }

        let degrees = atan2(normalizedY, normalizedX) * 180 / .pi
        if degrees >= 150 {
            return Self.pieces[0]
        } else if degrees >= 120 {
            return Self.pieces[1]
        } else if degrees >= 90 {
            return Self.pieces[2]
        } else if degrees >= 60 {
            return Self.pieces[3]
        } else if degrees >= 30 {
            return Self.pieces[4]
        } else {
            return Self.pieces[5]
        }
    }

    private func wedgePath(
        center: CGPoint,
        horizontalRadius: CGFloat,
        verticalRadius: CGFloat,
        startDegrees: Double,
        endDegrees: Double
    ) -> Path {
        var path = Path()
        path.move(to: center)
        let steps = max(Int(abs(startDegrees - endDegrees) / 3), 1)
        for step in 0...steps {
            let fraction = Double(step) / Double(steps)
            let degrees = startDegrees + (endDegrees - startDegrees) * fraction
            path.addLine(to: point(
                center: center,
                horizontalRadius: horizontalRadius,
                verticalRadius: verticalRadius,
                degrees: degrees
            ))
        }
        path.closeSubpath()
        return path
    }

    private func point(
        center: CGPoint,
        horizontalRadius: CGFloat,
        verticalRadius: CGFloat,
        degrees: Double
    ) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(
            x: center.x + horizontalRadius * cos(radians),
            y: center.y - verticalRadius * sin(radians)
        )
    }
}

#Preview {
    Form {
        Section("Air movement") {
            OscillationControl(
                mode: 2,
                facingPreset: 2,
                destinationPreset: -3,
                canPosition: true,
                selectMode: { _ in },
                moveToPreset: { _ in },
                jogClockwise: {},
                jogCounterClockwise: {},
                home: {}
            )
        }
    }
}
