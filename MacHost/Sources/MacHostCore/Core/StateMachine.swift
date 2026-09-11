import Foundation

public final class JobUnitStateMachine: @unchecked Sendable {
    private let lock = NSLock()
    private var _currentState: ItemState
    private var _lastError: String?
    
    public var currentState: ItemState {
        lock.lock()
        defer { lock.unlock() }
        return _currentState
    }
    
    public var lastError: String? {
        lock.lock()
        defer { lock.unlock() }
        return _lastError
    }
    
    public init(initialState: ItemState = .planned) {
        self._currentState = initialState
        self._lastError = nil
    }
    
    @discardableResult
    public func transition(to newState: ItemState, error: String? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard isValidTransition(from: _currentState, to: newState) else {
            return false
        }
        self._currentState = newState
        self._lastError = error
        return true
    }
    
    private func isValidTransition(from: ItemState, to: ItemState) -> Bool {
        switch (from, to) {
        case (.planned, .running):
            return true
        case (.running, .running), (.running, .committing),
             (.running, .indeterminate), (.running, .failed):
            return true
        case (.committing, .completed), (.committing, .indeterminate), (.committing, .failed):
            return true
        case (.indeterminate, .running), (.indeterminate, .committing),
             (.indeterminate, .completed), (.indeterminate, .failed):
            return true
        default:
            return false
        }
    }
}
