import Foundation
import SwiftUI

extension View {
    func onMessage<Message: NotificationCenter.AsyncMessage>(
        _ type: Message.Type, perform action: @escaping (Message) -> Void
    ) -> some View
    where Message.Subject: AnyObject {
        task {
            for await message in NotificationCenter.default.messages(of: nil, for: type) {
                action(message)
            }
        }
    }
}
