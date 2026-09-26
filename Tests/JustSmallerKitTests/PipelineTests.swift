import Foundation
import Testing
@testable import JustSmallerKit

struct PipelineTests {
    @Test func losslessUsesNoLossyTools() {
        let settings = OptimizationSettings()
        for format in ImageFormat.allCases {
            let facts = FileFacts(byteSize: 100_000, isLosslessWebP: true)
            for stage in Pipeline.stages(for: format, facts: facts, settings: settings) {
                #expect(stage.allSatisfy { !$0.isLossy }, "\(format) uses a lossy tool in lossless mode")
            }
        }
    }

    @Test func heicOnlyInLossyMode() {
        var settings = OptimizationSettings()
        let facts = FileFacts(byteSize: 1_000_000)
        #expect(Pipeline.stages(for: .heic, facts: facts, settings: settings).isEmpty)
        settings.lossy = true
        #expect(!Pipeline.stages(for: .heic, facts: facts, settings: settings).isEmpty)
        // 10-bit HDR photos would lose depth
        #expect(Pipeline.stages(for: .heic, facts: FileFacts(byteSize: 1, bitsPerComponent: 10), settings: settings).isEmpty)
    }

    @Test func lossyWebPAndAnimationsAreLeftAlone() {
        let settings = OptimizationSettings()
        #expect(Pipeline.stages(for: .webp, facts: FileFacts(byteSize: 1), settings: settings).isEmpty)
        #expect(Pipeline.stages(for: .webp, facts: FileFacts(byteSize: 1, isLosslessWebP: true, isAnimated: true), settings: settings).isEmpty)
    }

    @Test func gifIsLeftForALaterVersion() {
        #expect(Pipeline.stages(for: .gif, facts: FileFacts(byteSize: 100_000), settings: OptimizationSettings()).isEmpty)
    }
}
