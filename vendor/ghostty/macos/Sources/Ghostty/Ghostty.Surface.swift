import Foundation
import GhosttyKit

private final class PimSurfaceResizeScheduler: @unchecked Sendable {
    private struct Request {
        let surface: ghostty_surface_t
        let width: UInt32
        let height: UInt32
        let completion: (ghostty_surface_size_s) -> Void
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.pim.surface-resize", qos: .userInteractive)
    private var pending: Request?
    private var draining = false

    func submit(
        surface: ghostty_surface_t,
        width: UInt32,
        height: UInt32,
        completion: @escaping (ghostty_surface_size_s) -> Void
    ) {
        lock.lock()
        pending = Request(surface: surface, width: width, height: height, completion: completion)
        let shouldStart = !draining
        draining = true
        lock.unlock()
        if shouldStart {
            // During a live resize AppKit can produce a long stream of
            // intermediate sizes. Let that burst settle before touching
            // libghostty so its IO mailbox receives one useful resize.
            queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [self] in drain() }
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let request = pending else {
                draining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            ghostty_surface_set_size(request.surface, request.width, request.height)
            let size = ghostty_surface_size(request.surface)
            DispatchQueue.main.async {
                request.completion(size)
            }

            lock.lock()
            let morePending = pending != nil
            if !morePending { draining = false }
            lock.unlock()
            if !morePending { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}

extension Ghostty {
    /// Represents a single surface within Ghostty.
    ///
    /// NOTE(mitchellh): This is a work-in-progress class as part of a general refactor
    /// of our Ghostty data model. At the time of writing there's still a ton of surface
    /// functionality that is not encapsulated in this class. It is planned to migrate that
    /// all over.
    ///
    /// Wraps a `ghostty_surface_t`
    final class Surface: Sendable {
        /// A surface is sendable because it is just a reference type. Using the surface in parameters
        /// may be unsafe but the value itself is safe to send across threads.
        nonisolated(unsafe) private let surface: ghostty_surface_t
        private let pimResizeScheduler = PimSurfaceResizeScheduler()
        private static let pimInputQueue = DispatchQueue(
            label: "com.pim.surface-input",
            qos: .userInteractive)
        private static let pimCommandQueue = DispatchQueue(
            label: "com.pim.surface-command",
            qos: .userInteractive)

        /// Read the underlying C value for this surface. This is unsafe because the value will be
        /// freed when the Surface class is deinitialized.
        var unsafeCValue: ghostty_surface_t {
            surface
        }

        /// Initialize from the C structure.
        init(cSurface: ghostty_surface_t) {
            self.surface = cSurface
        }

        deinit {
            guard !Thread.isMainThread else {
                // The surface remains registered with the app and holds unretained
                // userdata until it is freed. When already on the main thread, free
                // it synchronously so teardown completes before we disappear.
                ghostty_surface_free(surface)
                return
            }
            // deinit is not guaranteed to happen on the main actor and our API
            // calls into libghostty must happen there so we capture the surface
            // value so we don't capture `self` and then we detach it in a task.
            // We can't wait for the task to succeed so this will happen sometime
            // but that's okay.
            let surface = self.surface
            Task.detached { @MainActor in
                ghostty_surface_free(surface)
            }
        }

        /// Submit a Pim surface resize without blocking AppKit on libghostty.
        /// Only the newest pending size is retained while a resize is in flight.
        nonisolated func sendPimSurfaceSize(
            width: UInt32,
            height: UInt32,
            completion: @escaping (ghostty_surface_size_s) -> Void
        ) {
            pimResizeScheduler.submit(
                surface: surface,
                width: width,
                height: height,
                completion: completion)
        }

        /// Send text for a Pim session switch. This only queues bytes to the
        /// PTY; it does not synchronously update AppKit state. Keep it off the
        /// main actor so a busy terminal renderer cannot stall AppKit while Pi
        /// is starting.
        nonisolated func sendPimResume(_ text: String) {
            let length = text.utf8CString.count
            guard length > 1 else { return }
            Self.pimCommandQueue.async { [self] in
                text.withCString { ptr in
                    ghostty_surface_text(self.surface, ptr, UInt(length - 1))
                }
            }
        }

        /// Send Pim focus state from AppKit's main actor. Do not move this to a
        /// background queue: focus changes can synchronously update SwiftUI state.
        nonisolated func sendPimFocus(_ focused: Bool) {
            ghostty_surface_set_focus(surface, focused)
        }

        /// Send Pim mouse button events from AppKit's main actor. libghostty may
        /// emit UI actions while handling the event, so these must not run on a
        /// background queue.
        nonisolated func sendPimMouseButton(
            _ state: ghostty_input_mouse_state_e,
            _ button: ghostty_input_mouse_button_e,
            _ mods: ghostty_input_mods_e,
            releasePressure: Bool = false
        ) {
            ghostty_surface_mouse_button(surface, state, button, mods)
            if releasePressure {
                ghostty_surface_mouse_pressure(surface, 0, 0)
            }
        }

        /// Send text to the terminal as if it was typed. This doesn't send the key events so keyboard
        /// shortcuts and other encodings do not take effect.
        @MainActor
        func sendText(_ text: String) {
            let len = text.utf8CString.count
            if len == 0 { return }

            text.withCString { ptr in
                // len includes the null terminator so we do len - 1
                ghostty_surface_text(surface, ptr, UInt(len - 1))
            }
        }

        /// Send a key event to the terminal.
        ///
        /// This sends the full key event including modifiers, action type, and text to the terminal.
        /// Unlike `sendText`, this method processes keyboard shortcuts, key bindings, and terminal
        /// encoding based on the complete key event information.
        ///
        /// - Parameter event: The key event to send to the terminal
        @MainActor
        func sendKeyEvent(_ event: Input.KeyEvent) {
            event.withCValue { cEvent in
                ghostty_surface_key(surface, cEvent)
            }
        }

        /// Check if a key event matches a keybinding.
        ///
        /// This checks whether the given key event would trigger a keybinding in the terminal.
        /// If it matches, returns the binding flags indicating properties of the matched binding.
        ///
        /// - Parameter event: The key event to check
        /// - Returns: The binding flags if a binding matches, or nil if no binding matches
        @MainActor
        func keyIsBinding(_ event: ghostty_input_key_s) -> Input.BindingFlags? {
            var flags = ghostty_binding_flags_e(0)
            guard ghostty_surface_key_is_binding(surface, event, &flags) else { return nil }
            return Input.BindingFlags(cFlags: flags)
        }

        /// See `keyIsBinding(_ event: ghostty_input_key_s)`.
        @MainActor
        func keyIsBinding(_ event: Input.KeyEvent) -> Input.BindingFlags? {
            event.withCValue { keyIsBinding($0) }
        }

        /// Whether the terminal has captured mouse input.
        ///
        /// When the mouse is captured, the terminal application is receiving mouse events
        /// directly rather than the host system handling them. This typically occurs when
        /// a terminal application enables mouse reporting mode.
        @MainActor
        var mouseCaptured: Bool {
            ghostty_surface_mouse_captured(surface)
        }

        /// The PID of the foreground process group attached to the PTY.
        @MainActor
        var foregroundPID: Int? {
            let pid = ghostty_surface_foreground_pid(surface)
            guard pid != 0 else { return nil }
            return Int(exactly: pid)
        }

        /// The PTY device name for this surface.
        @MainActor
        var ttyName: String? {
            let ttyName = AllocatedString(ghostty_surface_tty_name(surface)).string
            return ttyName.isEmpty ? nil : ttyName
        }

        /// Send a mouse button event to the terminal.
        ///
        /// This sends a complete mouse button event including the button state (press/release),
        /// which button was pressed, and any modifier keys that were held during the event.
        /// The terminal processes this event according to its mouse handling configuration.
        ///
        /// - Parameter event: The mouse button event to send to the terminal
        @MainActor
        func sendMouseButton(_ event: Input.MouseButtonEvent) {
            ghostty_surface_mouse_button(
                surface,
                event.action.cMouseState,
                event.button.cMouseButton,
                event.mods.cMods)
        }

        /// Send a mouse position event to the terminal.
        ///
        /// This reports the current mouse position to the terminal, which may be used
        /// for mouse tracking, hover effects, or other position-dependent features.
        /// The terminal will only receive these events if mouse reporting is enabled.
        ///
        /// - Parameter event: The mouse position event to send to the terminal
        @MainActor
        func sendMousePos(_ event: Input.MousePosEvent) {
            if Bundle.main.bundleURL.lastPathComponent == "Pim.app" {
                // Keep terminal link hit-testing off AppKit. Its UI actions are
                // marshalled back to the main actor by Ghostty.App below.
                let x = event.x
                let y = event.y
                let mods = event.mods.cMods
                Self.pimInputQueue.async { [self] in
                    ghostty_surface_mouse_pos(self.surface, x, y, mods)
                }
                return
            }
            ghostty_surface_mouse_pos(
                surface,
                event.x,
                event.y,
                event.mods.cMods)
        }

        /// Send a mouse scroll event to the terminal.
        ///
        /// This sends scroll wheel input to the terminal with delta values for both
        /// horizontal and vertical scrolling, along with precision and momentum information.
        /// The terminal processes this according to its scroll handling configuration.
        ///
        /// - Parameter event: The mouse scroll event to send to the terminal
        @MainActor
        func sendMouseScroll(_ event: Input.MouseScrollEvent) {
            if Bundle.main.bundleURL.lastPathComponent == "Pim.app" {
                let x = event.x
                let y = event.y
                let mods = event.mods.cScrollMods
                Self.pimInputQueue.async { [self] in
                    ghostty_surface_mouse_scroll(self.surface, x, y, mods)
                }
                return
            }
            ghostty_surface_mouse_scroll(
                surface,
                event.x,
                event.y,
                event.mods.cScrollMods)
        }

        /// Perform a keybinding action.
        ///
        /// The action can be any valid keybind parameter. e.g. `keybind = goto_tab:4`
        /// you can perform `goto_tab:4` with this.
        ///
        /// Returns true if the action was performed. Invalid actions return false.
        @MainActor
        func perform(action: String) -> Bool {
            let len = action.utf8CString.count
            if len == 0 { return false }
            return action.withCString { cString in
                ghostty_surface_binding_action(surface, cString, UInt(len - 1))
            }
        }
    }
}
