public enum TrolleyAction {
    case findElement(ElementQuery)
    case click(AXElementProviding)
    case focus(AXElementProviding)
    case key(name: String, modifiers: [String])
    case type(String)
    case wait(seconds: Double)
}

public enum ActionResult {
    case elementFound([AXMatch])
    case ok
    case failed(String)
}
