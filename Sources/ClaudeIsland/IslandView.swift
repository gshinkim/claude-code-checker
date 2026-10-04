import SwiftUI

/// Slides left and right three times as `animatableData` goes from n to n+1.
struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(animatableData * .pi * 6), y: 0))
    }
}

struct SessionRow: View {
    let session: Session

    private var label: String {
        switch session.state {
        case .idle: "Idle"
        case .working: "Working"
        case .done: "Done"
        case .needsYou: "Needs you"
        }
    }
    private var color: Color {
        switch session.state {
        case .idle: .gray
        case .working: .blue
        case .done: .green
        case .needsYou: .orange
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: session.cwd).lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(session.hostName ?? "Unknown") · \(label)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(session.updatedAt, style: .relative)
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(session.attention ? Color.orange.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}

struct IslandView: View {
    @ObservedObject var store: SessionStore
    let notch: CGSize
    @State private var expanded = false
    @State private var shakes: CGFloat = 0

    private let wing: CGFloat = 34
    private var attentionCount: Int { store.sessions.filter(\.attention).count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PetView(size: 24, jumps: shakes).frame(width: wing).opacity(expanded ? 0 : 1)
                Spacer(minLength: notch.width)
                Text(attentionCount > 0 ? "\(attentionCount)" : "")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.orange)
                    .frame(width: wing)
            }
            .frame(height: notch.height)
            if expanded { list }
        }
        .frame(width: expanded ? max(360, notch.width + wing * 2) : notch.width + wing * 2)
        .background(.black)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(.spring(duration: 0.3)) { expanded = hovering } }
        .contextMenu { Button("Quit Claude Island") { NSApp.terminate(nil) } }
        .modifier(Shake(animatableData: shakes))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onReceive(store.$alertTick.dropFirst()) { _ in
            withAnimation(.linear(duration: 0.7)) { shakes += 1 }
        }
    }

    private var list: some View {
        HStack(alignment: .top, spacing: 12) {
            PetView(size: 48, jumps: shakes)
            VStack(alignment: .leading, spacing: 6) {
                if store.sessions.isEmpty {
                    Text("No Claude Code sessions").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                // ponytail: shows the first 6 sessions; add a ScrollView if more are ever run at once
                ForEach(store.sessions.prefix(6)) { s in
                    SessionRow(session: s).onTapGesture {
                        store.clearAttention(s)
                        Jumper.jump(to: s)
                    }
                }
            }
        }
        .padding(12)
    }
}
