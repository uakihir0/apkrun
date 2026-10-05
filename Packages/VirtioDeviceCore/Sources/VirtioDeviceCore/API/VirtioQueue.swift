/// A virtqueue that drains every available element.
public protocol VirtioQueue {
    /// Calls `body` for each available element until the queue is empty.
    ///
    /// The body is nonthrowing because Virtualization.framework suppresses queue
    /// notifications until every available element has been consumed. Handle
    /// per-element failures inside the body and still complete the element.
    func drain(_ body: (consuming VirtioElement) -> Void)
}
