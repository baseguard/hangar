package struct CreationProgress: Sendable {
    package var phase: String
    package var fraction: Double?
    package var detail: String?

    package init(phase: String, fraction: Double? = nil, detail: String? = nil) {
        self.phase = phase
        self.fraction = fraction
        self.detail = detail
    }
}

package typealias ProgressHandler = @Sendable (CreationProgress) -> Void
