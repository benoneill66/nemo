import SwiftUI

// MARK: - People pane (plan 16)

/// The people directory: everyone Nemo has built up context on, from spoken mentions, imports,
/// and named voices. A master list on the left, a rich person detail (facts, attributes, linked
/// memories and voices, with merge) on the right.
struct PeoplePane: View {
    @EnvironmentObject var state: AppState
    @State private var selected: UUID?
    @State private var query = ""

    private var shown: [Person] {
        let base = state.sortedPeople
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return base }
        return base.filter { p in
            p.knownNames.contains { $0.contains(q) }
                || p.displaySummary.lowercased().contains(q)
                || p.facts.contains { $0.text.lowercased().contains(q) }
        }
    }
    private let cols = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)]

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                PeoplePaneHeader(title: "People",
                                 subtitle: "Everyone Nemo knows — context that grows over time.")

                if state.people.count > 4 {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                        TextField("Search people", text: $query).textFieldStyle(.plain)
                            .font(.system(size: 13)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(Capsule().fill(.white.opacity(0.08)))
                }

                if state.people.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: cols, alignment: .leading, spacing: 12) {
                            ForEach(shown) { p in
                                PersonCard(person: p, speakerCount: p.speakerIds.count,
                                           selected: selected == p.id) { selected = p.id }
                            }
                        }
                    }
                }
            }
            .padding(20)
            .glassCard(cornerRadius: 22)

            if let id = selected, let live = state.person(id) {
                PersonDetail(person: live) { selected = nil }
                    .frame(width: 340)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2.fill").font(.system(size: 40)).foregroundStyle(.white.opacity(0.4))
            Text("No people yet").font(.system(size: 15, weight: .semibold))
            Text("As Nemo hears about the people in your life, it builds a profile for each — and you can name a voice in the Live tab to attach it to a person.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PeoplePaneHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 24, weight: .bold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Person card

private struct PersonCard: View {
    let person: Person
    let speakerCount: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Avatar(person: person, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(person.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            .lineLimit(1)
                        if !person.attributeLine.isEmpty {
                            Text(person.attributeLine).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if person.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.yellow.opacity(0.85)) }
                }
                if !person.displaySummary.isEmpty {
                    Text(person.displaySummary).font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
                        .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 6) {
                    if !person.facts.isEmpty { GlassPill(text: "\(person.facts.count)", systemImage: "note.text", hue: person.hue) }
                    if !person.memoryIds.isEmpty { GlassPill(text: "\(person.memoryIds.count)", systemImage: "brain", hue: person.hue) }
                    if speakerCount > 0 { GlassPill(text: "\(speakerCount)", systemImage: "waveform", hue: person.hue) }
                    if person.aliases.count > 0 { GlassPill(text: "\(person.aliases.count) alias\(person.aliases.count == 1 ? "" : "es")", hue: person.hue) }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 16, tintHue: person.hue)
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(selected ? 0.6 : 0), lineWidth: 1.5))
        }.buttonStyle(.plain)
    }
}

/// A circular monogram tinted by the person's stable hue.
private struct Avatar: View {
    let person: Person
    var size: CGFloat = 34
    private var initials: String {
        let parts = person.name.split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first }.map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }
    var body: some View {
        Circle()
            .fill(Color(hue: person.hue, saturation: 0.55, brightness: 0.9).opacity(0.4))
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .overlay(Text(initials).font(.system(size: size * 0.38, weight: .bold)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}

// MARK: - Person detail

private struct PersonDetail: View {
    @EnvironmentObject var state: AppState
    let person: Person
    let close: () -> Void

    @State private var editing = false
    @State private var draftName = ""
    @State private var draftSummary = ""
    @State private var draftRelationship = ""

    private var attachableSpeakers: [SpeakerIdentity] {
        state.speakers.filter { !person.speakerIds.contains($0.id) }
            .sorted { $0.id < $1.id }
    }
    private var mergeCandidates: [Person] {
        state.sortedPeople.filter { $0.id != person.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if editing { editor } else { reader }
            }
            .padding(18)
        }
        .glassCard(cornerRadius: 22, tintHue: person.hue)
        .onChange(of: person.id) { _ in editing = false }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(person: person, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                if !person.attributeLine.isEmpty {
                    Text(person.attributeLine).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                }
                Text("known since \(person.firstSeen, format: .dateTime.month().day().year()) · \(person.mentionCount) mention\(person.mentionCount == 1 ? "" : "s")")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5))
            }.buttonStyle(.plain)
        }
    }

    @ViewBuilder private var reader: some View {
        if !person.displaySummary.isEmpty {
            Text(person.displaySummary).font(.system(size: 13)).foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }

        if !person.aliases.isEmpty {
            sectionLabel("Also known as")
            FlowPills(items: person.aliases, hue: person.hue)
        }

        let attrs = person.attributes.filter { !["source"].contains($0.key) && !$0.value.isEmpty }
        if !attrs.isEmpty {
            sectionLabel("Details")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(attrs.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                    HStack(alignment: .top, spacing: 6) {
                        Text(k.capitalized).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                            .frame(width: 88, alignment: .leading)
                        Text(v).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        if !person.facts.isEmpty {
            sectionLabel("What Nemo knows")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(person.facts.reversed()) { fact in
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill(Color(hue: person.hue, saturation: 0.6, brightness: 1).opacity(0.8))
                            .frame(width: 5, height: 5).padding(.top, 6)
                        Text(fact.text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.88))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        // Linked voices.
        let voices = state.speakers.filter { person.speakerIds.contains($0.id) }
        if !voices.isEmpty || !attachableSpeakers.isEmpty {
            sectionLabel("Voices")
            HStack(spacing: 6) {
                ForEach(voices) { sp in
                    GlassPill(text: sp.name, systemImage: "waveform", hue: sp.hue)
                }
                if !attachableSpeakers.isEmpty {
                    Menu {
                        ForEach(attachableSpeakers) { sp in
                            Button(sp.name) { state.attachSpeaker(sp.id, toPersonId: person.id) }
                        }
                    } label: {
                        Label("Attach a voice", systemImage: "plus.circle")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    }.menuStyle(.borderlessButton).fixedSize()
                }
            }
        }

        // Linked memories.
        let mems = person.memoryIds.compactMap { state.memory($0) }
            .sorted { $0.updated > $1.updated }
        if !mems.isEmpty {
            sectionLabel("Mentioned in")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(mems.prefix(8)) { m in
                    HStack(spacing: 6) {
                        Image(systemName: m.categoryEnum.symbol).font(.system(size: 10))
                            .foregroundStyle(Color(hue: m.categoryEnum.hue, saturation: 0.6, brightness: 1))
                        Text(m.title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.82)).lineLimit(1)
                    }
                }
            }
        }

        actions
    }

    private var actions: some View {
        HStack(spacing: 14) {
            Button { state.setPersonPinned(person.id, !person.pinned) } label: {
                Image(systemName: person.pinned ? "pin.slash" : "pin")
                    .foregroundStyle(person.pinned ? .yellow.opacity(0.9) : .white.opacity(0.7))
            }.buttonStyle(.plain).help(person.pinned ? "Unpin" : "Pin")

            Button { beginEditing() } label: {
                Image(systemName: "pencil").foregroundStyle(.white.opacity(0.7))
            }.buttonStyle(.plain).help("Edit")

            if !mergeCandidates.isEmpty {
                Menu {
                    Text("Merge another person into \(person.name)")
                    ForEach(mergeCandidates.prefix(30)) { other in
                        Button("\(other.name)\(other.attributeLine.isEmpty ? "" : " — \(other.attributeLine)")") {
                            state.mergePeople(other.id, into: person.id)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.triangle.merge").foregroundStyle(.white.opacity(0.7))
                }.menuStyle(.borderlessButton).fixedSize().help("Merge a duplicate into this person")
            }

            Spacer()
            Button { state.deletePerson(person.id); close() } label: {
                Image(systemName: "trash").foregroundStyle(.red.opacity(0.8))
            }.buttonStyle(.plain).help("Delete")
        }
        .padding(.top, 6)
    }

    @ViewBuilder private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Name")
            TextField("Name", text: $draftName).textFieldStyle(.roundedBorder)
            sectionLabel("Relationship")
            TextField("e.g. colleague, sister", text: $draftRelationship).textFieldStyle(.roundedBorder)
            sectionLabel("Summary")
            TextEditor(text: $draftSummary)
                .font(.system(size: 12)).frame(height: 90).scrollContentBackground(.hidden)
                .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
            HStack {
                Button("Cancel") { editing = false }.controlSize(.small)
                Spacer()
                Button("Save") { commit() }.controlSize(.small).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func beginEditing() {
        draftName = person.name
        draftSummary = person.userEdited ? person.summary : person.displaySummary
        draftRelationship = person.attributes["relationship"] ?? ""
        editing = true
    }

    private func commit() {
        state.updatePerson(person.id, name: draftName, summary: draftSummary,
                           relationship: draftRelationship.trimmingCharacters(in: .whitespaces))
        editing = false
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.45)).padding(.top, 4)
    }
}
