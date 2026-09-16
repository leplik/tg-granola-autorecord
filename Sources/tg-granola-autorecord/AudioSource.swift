import AutorecordCore

struct SystemAudio: AudioSource {
    func snapshot() -> [AudioProcessState] {
        AudioProcesses.snapshot()
    }
}
