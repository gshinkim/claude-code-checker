import SwiftUI

/// Two happy hops as `animatableData` goes from n to n+1.
struct Jump: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        let lift = abs(sin(animatableData * .pi * 2)) * size.height * 0.45
        return ProjectionTransform(CGAffineTransform(translationX: 0, y: -lift))
    }
}

/// The pixel Claude creature, drawn on an 18 x 11 grid. Its eyes follow the cursor.
struct PetView: View {
    /// Width in points; height follows the 18:11 grid.
    let size: CGFloat
    var jumps: CGFloat
    @State private var bob = false
    private let orange = Color(red: 0.84, green: 0.50, blue: 0.38)

    /// How far the eyes shift, in grid units (x right, y down), for a cursor and pet in screen coordinates.
    static func eyeOffset(mouse: CGPoint, pet: CGPoint) -> CGSize {
        let dx = mouse.x - pet.x, dy = pet.y - mouse.y // screen y grows upward
        let dist = hypot(dx, dy)
        guard dist > 0 else { return .zero }
        let reach = min(dist, 300) / 300 // full deflection once the cursor is 300 pt away
        return CGSize(width: dx / dist * reach * 0.6, height: dy / dist * reach * 0.5)
    }

    /// The island sits at the top center of its panel; close enough for both pet sizes.
    private static var petLocation: CGPoint {
        NSApp.windows.first.map { CGPoint(x: $0.frame.midX, y: $0.frame.maxY - 16) } ?? .zero
    }

    var body: some View {
        // ponytail: polls the cursor 15x a second; switch to a global mouse-moved monitor if idle CPU ever matters
        TimelineView(.periodic(from: .now, by: 1.0 / 15)) { _ in
            let look = Self.eyeOffset(mouse: NSEvent.mouseLocation, pet: Self.petLocation)
            Canvas { ctx, canvas in
                let u = canvas.width / 18
                func block(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color) {
                    ctx.fill(Path(CGRect(x: x * u, y: y * u, width: w * u, height: h * u)), with: .color(color))
                }
                block(2, 0, 14, 9, orange)                                   // body
                block(0, 4, 2, 2, orange); block(16, 4, 2, 2, orange)        // arms
                for x: CGFloat in [3, 5, 12, 14] { block(x, 9, 1, 2, orange) } // legs
                for x: CGFloat in [4.5, 12.5] {                              // eyes
                    block(x + look.width, 2.5 + look.height, 1, 2, .black)
                }
            }
        }
        .frame(width: size, height: size * 11 / 18)
        .modifier(Jump(animatableData: jumps))
        .offset(y: bob ? -1 : 1)
        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: bob)
        .onAppear { bob = true }
    }
}
