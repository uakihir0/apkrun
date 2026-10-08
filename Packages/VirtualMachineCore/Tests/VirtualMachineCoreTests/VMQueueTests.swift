import Testing

@testable import VirtualMachineCore

@Test func vmQueueHasTheDocumentedLabelByDefault() {
    #expect(VMQueue().dispatchQueue.label == "io.apkrun.vm.queue")
}

@Test func vmQueueRunsSynchronousWorkOnItsOwnQueue() {
    let queue = VMQueue()

    #expect(!queue.isCurrent())
    #expect(queue.performSynchronously { queue.isCurrent() })
}
