import Combine

public final class RefreshSignal: ObservableObject {
    @Published public var tick: Int = 0
    @Published public var optionHeld: Bool = false
    @Published public var showSettings: Bool = false
    @Published public var showTestKitConsent: Bool = false

    public init() {}

    public func bump() { tick &+= 1 }
}
