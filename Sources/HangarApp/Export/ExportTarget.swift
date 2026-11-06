import HangarKit

struct ExportTarget: Identifiable {
    let vm: String
    let os: GuestOS
    let snapshot: VMSnapshot?

    var id: String { vm + "/" + (snapshot?.name ?? "") }
}
