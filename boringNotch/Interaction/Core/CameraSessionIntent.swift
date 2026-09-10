// Custom changes for 工位充电岛. Owned exclusively by the camera's serial queue.
struct CameraSessionIntent {
    private(set) var desiredRunning = false
    private(set) var generation: UInt64 = 0

    mutating func requestStart() -> UInt64 {
        generation &+= 1
        desiredRunning = true
        return generation
    }

    mutating func requestStop() {
        generation &+= 1
        desiredRunning = false
    }

    func accepts(_ generation: UInt64) -> Bool {
        desiredRunning && self.generation == generation
    }
}
