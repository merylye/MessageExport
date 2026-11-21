import Contacts
import Foundation
import MessagesCore

enum MacContacts {
    /// Loads names from the Contacts app. Asks for permission the first time.
    /// Returns an empty directory if the user declines.
    static func load() async -> ContactDirectory {
        let directory = ContactDirectory()
        let store = CNContactStore()
        let granted: Bool
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = (try? await store.requestAccess(for: .contacts)) ?? false
        default:
            granted = false
        }
        guard granted else { return directory }

        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: request) { contact, _ in
            var name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
            if name.isEmpty { name = contact.organizationName }
            let handles = contact.phoneNumbers.map { $0.value.stringValue }
                + contact.emailAddresses.map { $0.value as String }
            directory.add(name: name, handles: handles)
        }
        return directory
    }
}
