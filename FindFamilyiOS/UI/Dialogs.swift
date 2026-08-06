import SwiftUI

// MARK: - AddPersonDialog

struct AddPersonDialog: View {
    let presetID: Int64?
    @Binding var isPresented: Bool

    @State private var theirIDStr: String = ""
    @State private var contactName: String?
    @State private var contactPhoto: String?
    @State private var justCopied = false

    private var myIDStr: String { Base26.encode(Networking.shared.userid) }

    private var theirID: Int64? {
        if let preset = presetID { return preset }
        return Base26.decode(theirIDStr)
    }

    private var existingUser: User? {
        guard let id = theirID else { return nil }
        return Database.shared.user(id: id)
    }

    private var status: RequestStatus? { existingUser?.requestStatus }

    private var statusMessage: (String, Bool)? {
        guard let id = theirID else { return nil }
        if id == Networking.shared.userid { return (Strings.addPersonSelf, true) }
        guard let status = status else { return nil }
        switch status {
        case .awaitingRequest: return (Strings.addPersonAwaitingRequest, false)
        case .mutualConnection: return (Strings.addPersonAlreadyMutual, true)
        case .awaitingResponse: return (Strings.addPersonAlreadyRequested, true)
        }
    }

    private var submitEnabled: Bool {
        guard let id = theirID, id != Networking.shared.userid,
              let name = contactName, !name.isEmpty else { return false }
        if let s = status, s == .mutualConnection || s == .awaitingResponse { return false }
        return true
    }

    private var submitLabel: String {
        status == .awaitingRequest ? Strings.addPersonAccept : Strings.addPersonSubmit
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(Strings.addPersonYourID) {
                    Button {
                        copyMyID()
                    } label: {
                        HStack {
                            Text(myIDStr).font(.body.monospaced()).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(justCopied ? .green : .accentColor)
                                .contentTransition(.symbolEffect(.replace))
                            if justCopied {
                                Text("Copied")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                    .transition(.opacity)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Share sheet instead of copy/paste: sends findfamily://add/<myId>,
                    // which prefills the recipient's Add Person dialog. The link carries
                    // only a public id — never a key — so it's safe to share anywhere.
                    Button {
                        Platform.share("findfamily://add/\(myIDStr)")
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text(Strings.shareInviteLink)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                }
                Section(Strings.addPersonTheirID) {
                    if presetID != nil {
                        Text(Base26.encode(presetID!)).font(.body.monospaced())
                    } else {
                        TextField("ABCDE", text: $theirIDStr)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                    }
                    if let (msg, isError) = statusMessage {
                        Text(msg).font(.caption).foregroundStyle(isError ? .red : .secondary)
                    }
                }
                Section(Strings.addPersonName) {
                    Button {
                        Platform.presentContactPicker { name, photo in
                            contactName = name
                            contactPhoto = photo
                        }
                    } label: {
                        HStack {
                            Text(contactName ?? "Pick a contact").foregroundStyle(contactName == nil ? .secondary : .primary)
                            Spacer()
                            Image(systemName: "person.crop.circle")
                        }
                    }
                }
                Section {
                    Button(submitLabel) { submit() }
                        .disabled(!submitEnabled)
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Add Person")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Strings.cancelButton) { isPresented = false }
                }
            }
        }
    }

    private func submit() {
        guard let id = theirID, let name = contactName else { return }
        let isAccepting = (status == .awaitingRequest)
        let newStatus: RequestStatus = isAccepting ? .mutualConnection : .awaitingResponse
        let user = User(
            id: id,
            name: name,
            photo: contactPhoto,
            locationName: "Unknown Location",
            sendingEnabled: true,
            requestStatus: newStatus,
            lastLocationChangeTime: Date(),
            encryptionKey: nil,
            pqcEncryptionKey: nil
        )
        Database.shared.upsertUser(user)
        isPresented = false
    }

    private func copyMyID() {
        Platform.copy(myIDStr)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.easeInOut(duration: 0.2)) { justCopied = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeInOut(duration: 0.2)) { justCopied = false }
        }
    }
}

// MARK: - AddLinkDialog

struct AddLinkDialog: View {
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var expirySeconds: TimeInterval = 60 * 60   // 1h default
    @State private var working = false

    private let expiryOptions: [(label: String, seconds: TimeInterval)] = [
        ("15 minutes", 15 * 60),
        ("30 minutes", 30 * 60),
        ("1 hour", 60 * 60),
        ("2 hours", 2 * 60 * 60),
        ("4 hours", 4 * 60 * 60),
        ("6 hours", 6 * 60 * 60),
        ("12 hours", 12 * 60 * 60),
        ("1 day", 24 * 60 * 60),
        ("2 days", 2 * 24 * 60 * 60),
        ("1 week", 7 * 24 * 60 * 60),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section(Strings.addLinkLabelField) {
                    TextField("Label", text: $name)
                }
                Section(Strings.addLinkExpiryField) {
                    Picker("Expiry", selection: $expirySeconds) {
                        ForEach(expiryOptions, id: \.seconds) { opt in
                            Text(opt.label).tag(opt.seconds)
                        }
                    }
                }
                Section {
                    Button(Strings.addLinkSubmit) { submit() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || working)
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(Strings.addLinkTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Strings.cancelButton) { isPresented = false }
                }
            }
        }
    }

    private func submit() {
        working = true
        Task {
            do {
                let (priv, pub) = try RSAKeyManager.shared.generateEphemeralKeyPair()
                let priPEM = try RSAPEM.privateKeyToPEM(priv)
                let pubPEM = try RSAPEM.publicKeyToPEM(pub)
                let priB64 = Data(priPEM.utf8).base64EncodedString()
                let pubB64 = Data(pubPEM.utf8).base64EncodedString()
                // PQC ephemeral — best effort, RSA still works if native not linked.
                var pqcPublicB64: String? = nil
                var pqcPrivateB64: String? = nil
                do {
                    let ep = try PQCKeyManager.shared.generateEphemeralBundle()
                    pqcPublicB64 = ep.publicB64
                    pqcPrivateB64 = ep.privateB64
                } catch {
                    print("AddLink: PQC ephemeral unavailable (native not linked?): \(error.localizedDescription)")
                }
                let link = TemporaryLink(
                    id: 0,
                    name: name.trimmingCharacters(in: .whitespaces),
                    key: priB64,
                    publicKey: pubB64,
                    deleteAt: Date().addingTimeInterval(expirySeconds),
                    pqcPublicKey: pqcPublicB64,
                    pqcKey: pqcPrivateB64
                )
                _ = Database.shared.upsertTemporaryLink(link)
            } catch {
                print("AddLink error: \(error)")
            }
            working = false
            isPresented = false
        }
    }
}
