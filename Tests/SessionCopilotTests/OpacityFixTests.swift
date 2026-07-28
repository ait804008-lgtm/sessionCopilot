import Foundation
import Testing
import Combine
@testable import SessionCopilot

// MARK: - Verify opacity + clickThrough fire objectWillChange

@Suite("OverlayViewModel Opacity Fix") @MainActor struct OverlayViewModelOpacityFixTests {

    @Test("opacity didSet calls onChanged via objectWillChange")
    func opacityFiresObjectWillChange() {
        let vm = OverlayViewModel()
        var fired = false
        let cancellable = vm.objectWillChange.sink { _ in
            fired = true
        }

        vm.opacity = 0.5
        #expect(fired, "objectWillChange should fire when opacity changes")

        cancellable.cancel()
    }

    @Test("opacity didSet clamps to valid range AND fires onChanged")
    func opacityClampsAndFires() {
        let vm = OverlayViewModel()
        var fireCount = 0
        let cancellable = vm.objectWillChange.sink { _ in
            fireCount += 1
        }

        vm.opacity = 1.5  // Should clamp to 1.0
        #expect(vm.opacity == 1.0)
        #expect(fireCount >= 1, "objectWillChange should fire even when clamping")

        vm.opacity = -0.5 // Should clamp to 0.1
        #expect(vm.opacity == 0.1)
        #expect(fireCount >= 2, "objectWillChange should fire on clamp too")

        cancellable.cancel()
    }

    @Test("opacity within range fires onChanged")
    func opacityInRangeFires() {
        let vm = OverlayViewModel()
        var fired = false
        let cancellable = vm.objectWillChange.sink { _ in
            fired = true
        }

        vm.opacity = 0.3
        #expect(vm.opacity == 0.3)
        #expect(fired)

        cancellable.cancel()
    }

    @Test("multiple opacity changes all fire")
    func multipleOpacityChanges() {
        let vm = OverlayViewModel()
        var count = 0
        let cancellable = vm.objectWillChange.sink { _ in
            count += 1
        }

        vm.opacity = 0.2
        vm.opacity = 0.5
        vm.opacity = 0.9
        #expect(count == 3)

        cancellable.cancel()
    }
}
