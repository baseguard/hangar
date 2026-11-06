extension String {
    package init(nulTerminated characters: [CChar]) {
        self.init(decoding: characters.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
