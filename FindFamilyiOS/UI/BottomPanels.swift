import SwiftUI

// MARK: - Default list

struct DefaultList: View {
    let users: [User]
    let latestLocations: [Int64: LocationValue]
    let temporaryLinks: [TemporaryLink]
    let waypoints: [Waypoint]
    let onSelectUser: (Int64) -> Void
    let onSelectWaypoint: (Waypoint) -> Void
    let onTapRequest: (Int64) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(users.filter { $0.requestStatus == .mutualConnection || $0.requestStatus == .awaitingResponse }) { u in
                UserCard(user: u, latest: latestLocations[u.id], showSupporting: true) {
                    onSelectUser(u.id)
                }
            }
            let requests = users.filter { $0.requestStatus == .awaitingRequest }
            if !requests.isEmpty {
                Text(Strings.sectionLocationSharingRequests)
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
            }
            ForEach(requests) { u in
                AwaitingRequestCard(id: u.id) { onTapRequest(u.id) }
            }
            if !temporaryLinks.isEmpty {
                Text(Strings.sectionTemporaryLinks)
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
            }
            ForEach(temporaryLinks) { link in
                TemporaryLinkCard(link: link)
            }
            if !waypoints.isEmpty {
                Text(Strings.sectionSavedPlaces)
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
            }
            ForEach(waypoints) { wp in
                WaypointCard(waypoint: wp, users: users) { onSelectWaypoint(wp) }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
    }
}

// MARK: - User detail panel

struct UserDetailPanel: View {
    let user: User
    let latest: LocationValue?
    let onChangeContact: (String, String?) -> Void
    let onToggleSending: (Bool) -> Void

    @State private var showPqcInfo = false

    var body: some View {
        VStack(spacing: 12) {
            UserCard(user: user, latest: latest, showSupporting: true) {}
            // PQC status banner for unprotected connections (also tappable via lock in card)
            if user.id != Networking.shared.userid && user.pqcEncryptionKey == nil {
                Button { showPqcInfo = true } label: {
                    Label(Strings.pqcUnprotectedMessage, systemImage: "lock.open.trianglebadge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.red.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            HStack {
                Text(Strings.shareYourLocation)
                Spacer()
                Toggle("", isOn: Binding(get: { user.sendingEnabled }, set: { onToggleSending($0) }))
                    .labelsHidden()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))

            // Precision Finding entry — pushed onto the MainView's NavigationStack.
            NavigationLink(value: user) {
                Label("Find with Precision", systemImage: "location.north.line.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button(Strings.changeConnectedContact) {
                Platform.presentContactPicker { name, photo in
                    onChangeContact(name, photo)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .alert(Strings.pqcUnprotectedTitle, isPresented: $showPqcInfo) {
            Button(Strings.okButton, role: .cancel) {}
        } message: {
            Text(Strings.pqcUnprotectedMessage)
        }
    }
}

// MARK: - Waypoint editor panel

struct WaypointEditorPanel: View {
    @Binding var name: String
    @Binding var range: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(Strings.addLinkLabelField, text: $name)
                .textFieldStyle(.roundedBorder)
            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(Strings.waypointNameBlankError).font(.caption).foregroundStyle(.red)
            }

            HStack {
                TextField(Strings.waypointRangeSuffix, text: $range)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                Text(Strings.waypointRangeSuffix).foregroundStyle(.secondary)
            }
            if Double(range) == nil {
                Text(Strings.waypointRangeError).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
    }
}

// MARK: - Add menu (FAB)

struct AddMenu: View {
    let onAddPerson: () -> Void
    let onAddWaypoint: () -> Void
    let onAddLink: () -> Void

    @State private var expanded = false

    var body: some View {
        VStack(spacing: 12) {
            if expanded {
                MenuButton(icon: "person.fill", text: Strings.fabPerson) {
                    expanded = false
                    onAddPerson()
                }
                MenuButton(icon: "mappin.and.ellipse", text: Strings.fabLocation) {
                    expanded = false
                    onAddWaypoint()
                }
                MenuButton(icon: "link", text: Strings.fabLink) {
                    expanded = false
                    onAddLink()
                }
            }
            Button { withAnimation { expanded.toggle() } } label: {
                Image(systemName: expanded ? "xmark" : "plus")
                    .font(.title2)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(Circle())
                    .shadow(radius: 4)
            }
        }
    }
}

private struct MenuButton: View {
    let icon: String
    let text: String
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack {
                Text(text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Capsule())
                Image(systemName: icon)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(Circle())
                    .shadow(radius: 2)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Backup buttons

struct BackupButtons: View {
    @State private var exportURL: URL?
    @State private var showExport = false
    @State private var showImport = false

    var body: some View {
        HStack {
            Button {
                if let u = BackupManager.export() {
                    exportURL = u
                    showExport = true
                }
            } label: { Image(systemName: "square.and.arrow.up") }

            Button {
                showImport = true
            } label: { Image(systemName: "square.and.arrow.down") }
        }
        .sheet(isPresented: $showExport) {
            if let u = exportURL {
                ExportDocumentPicker(url: u) { showExport = false }
            }
        }
        .sheet(isPresented: $showImport) {
            ImportDocumentPicker { url in
                BackupManager.import(from: url)
                showImport = false
            }
        }
    }
}
