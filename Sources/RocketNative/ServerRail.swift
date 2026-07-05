import SwiftUI

/// Vertical workspace switcher on the window's leading edge — lateral tabs,
/// deliberately narrow so the horizontal tab space stays free for future
/// conversation tabs. ⌘1…⌘9 switch servers.
struct ServerRail: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(session.accounts.enumerated()), id: \.element.id) { index, account in
                ServerRailButton(
                    account: account,
                    isActive: account.id == session.activeAccount?.id,
                    badge: session.notifications.badge(for: account.id),
                    shortcutIndex: index)
            }
            addServerButton
            Spacer()
        }
        .padding(.vertical, 12)
        .frame(width: 56)
        .background(.thinMaterial)
    }

    private var addServerButton: some View {
        Button {
            session.showAddServer = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Add a server…")
    }
}

struct ServerRailButton: View {
    @Environment(AppSession.self) private var session
    let account: ServerAccount
    let isActive: Bool
    let badge: NotificationManager.AccountBadge
    let shortcutIndex: Int

    var body: some View {
        Button {
            session.activeAccountId = account.id
        } label: {
            ZStack(alignment: .topTrailing) {
                Text(account.railInitial)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(isActive ? Color.white : .primary)
                    .frame(width: 36, height: 36)
                    .background(isActive
                        ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(Color.secondary.opacity(0.18)))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                isActive ? Color.accentColor : .clear, lineWidth: 2)
                            .padding(-3)
                    }
                if badge.personal > 0 {
                    Text(badge.personal > 99 ? "99+" : "\(badge.personal)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(Color.red)
                        .clipShape(Capsule())
                        .offset(x: 6, y: -5)
                } else if badge.hasUnread {
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 8, height: 8)
                        .offset(x: 3, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
        .help("\(account.id) — \(account.profile.username ?? "")")
        .contextMenu {
            Text(account.id)
            Divider()
            Button("Log Out of \(account.displayName)", role: .destructive) {
                Task { await session.logout(accountId: account.id) }
            }
        }
        .modifier(RailShortcut(index: shortcutIndex))
    }
}

/// ⌘1…⌘9 for the first nine servers.
private struct RailShortcut: ViewModifier {
    let index: Int

    func body(content: Content) -> some View {
        if index < 9, let key = Character("\(index + 1)").unicodeScalars.first {
            content.keyboardShortcut(
                KeyEquivalent(Character(key)), modifiers: .command)
        } else {
            content
        }
    }
}
