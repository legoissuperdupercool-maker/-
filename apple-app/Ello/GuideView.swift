import SwiftUI

/// TV guide: pick a channel, see what's on, and replay earlier shows when
/// the provider archives the channel (catch-up).
struct GuideView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Channel?
    @State private var query = ""
    @State private var items: [Programme] = []
    @State private var loading = false

    private var channels: [Channel] {
        let list = model.favoriteChannels + model.live.filter { !model.isFavorite($0) }
        return query.isEmpty ? list : list.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 10) {
                SearchField(text: $query, prompt: "Find a channel")
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(channels) { c in
                            Button { selected = c } label: {
                                HStack(spacing: 12) {
                                    Artwork(url: c.logo, name: c.name, contentMode: .fit)
                                        .frame(width: 54, height: 36).background(Theme.surface2).clipShape(RoundedRectangle(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                        HStack(spacing: 6) {
                                            if model.isFavorite(c) { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                                            if c.catchupDays != nil { Text("Catch-up").foregroundStyle(Theme.blue) }
                                        }
                                        .font(.system(size: 11, weight: .semibold))
                                    }
                                    Spacer()
                                }
                                .padding(8)
                                .background(selected?.id == c.id ? Theme.surface2 : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.ello)
                        }
                    }
                }
            }
            .frame(width: 320)
            .padding(.leading, 28)

            VStack(alignment: .leading, spacing: 14) {
                if let c = selected {
                    HStack(spacing: 14) {
                        Text(c.name).font(.system(size: 26, weight: .bold)).lineLimit(1)
                        Spacer()
                        Button { model.play(c) } label: { Label("Watch live", systemImage: "play.fill") }
                            .buttonStyle(PillButtonStyle(primary: true))
                    }
                    if loading {
                        ProgressView().tint(Theme.blue).frame(maxWidth: .infinity).padding(.top, 40)
                    } else if items.isEmpty {
                        Text("Your provider has no guide for this channel.").foregroundStyle(Theme.dim).padding(.top, 30)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 8) {
                                    ForEach(items) { p in ProgrammeRow(programme: p, channel: c).id(p.id) }
                                }
                                .padding(.bottom, 30)
                            }
                            .onAppear {
                                if let now = items.first(where: { $0.stop > Date() }) { proxy.scrollTo(now.id, anchor: .top) }
                            }
                        }
                    }
                } else {
                    Text("Pick a channel to see what’s on.").foregroundStyle(Theme.dim).padding(.top, 40)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 28)
        }
        .task(id: selected?.id) {
            if selected == nil { selected = channels.first }
            guard let c = selected else { return }
            loading = true
            items = await model.guide(for: c)
            loading = false
        }
    }
}

struct ProgrammeRow: View {
    @Environment(AppModel.self) private var model
    let programme: Programme
    let channel: Channel

    private var isNow: Bool { programme.start <= Date() && programme.stop > Date() }
    private var isPast: Bool { programme.stop <= Date() }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(programme.start.formatted(date: .omitted, time: .shortened)).font(.system(size: 15, weight: .semibold))
                if !Calendar.current.isDateInToday(programme.start) {
                    Text(programme.start.formatted(.dateTime.weekday(.abbreviated))).font(.system(size: 12)).foregroundStyle(Theme.faint)
                }
            }
            .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if isNow {
                        Text("NOW").font(.system(size: 11, weight: .heavy)).padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Theme.bad, in: Capsule())
                    }
                    Text(programme.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                }
                if let d = programme.description, !d.isEmpty {
                    Text(d).font(.system(size: 13)).foregroundStyle(Theme.dim).lineLimit(2)
                }
                if isNow {
                    let f = Date().timeIntervalSince(programme.start) / programme.stop.timeIntervalSince(programme.start)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.15))
                            Capsule().fill(Theme.blue).frame(width: g.size.width * f)
                        }
                    }
                    .frame(height: 4).padding(.top, 4)
                }
            }
            Spacer()
            if isNow {
                Button { model.play(channel) } label: { Label("Watch", systemImage: "play.fill") }.buttonStyle(PillButtonStyle())
            } else if isPast && model.canReplay(programme, on: channel) {
                Button { model.playCatchup(programme, on: channel) } label: { Label("Replay", systemImage: "gobackward") }
                    .buttonStyle(PillButtonStyle())
            }
        }
        .padding(14)
        .background(isNow ? Theme.surface2 : Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .opacity(isPast && !model.canReplay(programme, on: channel) ? 0.55 : 1)
    }
}
