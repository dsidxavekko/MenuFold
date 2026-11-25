import AppKit
import MenuFoldCore
import SwiftUI

extension PanelController {
    // MARK: Deferred hide (drag in progress)

    func deferHideUntilDragEnd(_ reason: HideReason) {
        guard hideDeferredByDrag == nil else { return }
        hideDeferredByDrag = reason
        // Backstop for the case where no drag-end callback ever arrives: retry every 0.1 s for about
        // 3 s (then give up; `show()` also cancels this). Each retry re-reads `dragInProgress`, so a
        // normal drag-end clears the flag and the next tick applies the hide within 0.1 s.
        deferredHideRetryTask = Task { @MainActor [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(Self.deferredHideRetryInterval))
                guard let self, self.hideDeferredByDrag != nil else { return }
                if !self.dragInProgress { self.flushDeferredHide(); return }
            }
        }
    }

    /// Applies a hide that was postponed while a drag was live. One-shot by design: a deferred hide
    /// must never start a second fade-out or outlive the presentation it belongs to.
    func flushDeferredHide() {
        guard let reason = hideDeferredByDrag else { return }
        hideDeferredByDrag = nil
        deferredHideRetryTask?.cancel()
        deferredHideRetryTask = nil
        hide(reason: reason)
    }

    func cancelDeferredHide() {
        hideDeferredByDrag = nil
        deferredHideRetryTask?.cancel()
        deferredHideRetryTask = nil
    }


    // MARK: Dragging an app out of the panel

    /// While a tile drag is outside the panel, fade it and let clicks/drops through to what's under
    /// it (Desktop, Finder, Dock). Never ordered out mid-drag: that could cancel the session.
    func observeAppDrags() {
        let session = AppDragSession.shared
        session.onOutsidePanelChanged = { [weak self] outside in
            self?.setDragPassthrough(outside)
        }
        session.onEnded = { [weak self] droppedOutside in
            guard let self else { return }
            // Read before anything else can clear it: `dragPassthrough` is the only record that the
            // panel is dimmed from a drag, and every reset below runs before the fade-out's completion.
            let wasPassthrough = self.dragPassthrough
            self.endDragState()
            if droppedOutside {
                // The user chose to drop outside: close, fading from the current (dimmed) alpha, then
                // restore the window for the next presentation. `hide()` is called with the marker so
                // its drag deferral does not swallow this hide.
                self.inDragEnd = true
                self.hide()
                self.inDragEnd = false
                if self.hideInFlight, wasPassthrough { self.fadeOutAfterDrag() }
            } else {
                self.setDragPassthrough(false)
                // A resign-key hide that was postponed for the drag now owns the panel.
                self.flushDeferredHide()
            }
        }
    }

    /// Fade-out for a drag that ended outside the panel. Not `hide()`: that path reads drag state that
    /// `AppDragSession.ended` has already reset by the time its completion runs, so the panel would
    /// stay at 15 % alpha and click-through.
    func fadeOutAfterDrag() {
        guard isShown else { self.resetAfterHide(); return }
        isShown = false
        hideInFlight = true
        lastHide = Date()
        lastHideWasDockClick = false
        animateOut { [weak self] generation in
            guard let self, generation == self.motionGeneration, !self.isShown else { return }
            self.resetAfterHide()
        }
    }

    /// Shared tail of every hide: window hidden, motion and alpha back to the resting state, and the
    /// app deactivated only if no other MenuFold window (Settings) is visible.
    func resetAfterHide() {
        hideInFlight = false
        panel.orderOut(nil)
        resetMotion()
        panel.alphaValue = 1
        let otherVisible = NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.canBecomeMain }
        if !otherVisible, NSApp.isActive { NSApp.hide(nil) }
        scheduleViewUnload()
    }

    /// A hidden panel still keeps its whole SwiftUI tree (tiles, display lists, decoded icons), tens of
    /// MB. After a while without use the tree is dropped; `show()` rebuilds it while the panel is
    /// still transparent. View-local state (scroll position) is lost, the model's state is not.
    func scheduleViewUnload() {
        unloadTask?.cancel()
        unloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.unloadDelay)
            guard !Task.isCancelled, let self, !self.isShown, !self.panel.isVisible else { return }
            self.hostingView.rootView = AnyView(EmptyView())
            // A hidden window is not re-rendered, so without this the old graph would linger.
            self.hostingView.layoutSubtreeIfNeeded()
            self.viewsUnloaded = true
            IconCache.shared.removeAll()
            FileIconCache.shared.removeAll()
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    func restoreViewsIfNeeded() {
        unloadTask?.cancel()
        unloadTask = nil
        guard viewsUnloaded else { return }
        hostingView.rootView = rootContent
        viewsUnloaded = false
    }

    func setDragPassthrough(_ on: Bool) {
        if on {
            dragInProgress = true
            startDragWatchdog()
        } else {
            // Passthrough ends: stop the watchdog too, or it would tick forever when this runs after
            // `endDragState` cleared the drag (nothing else would ever stop it).
            stopDragWatchdog()
        }
        dragPassthrough = on
        panel.ignoresMouseEvents = on
        // Overrides a running open fade (the window animator keeps one alpha animation); a fade-out
        // in progress is left alone.
        guard isShown else { return }
        let panel = panel
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = on ? 0.15 : 1
        }
    }

    /// Clears everything a drag can leave behind: the click-through flag, the dimmed alpha and a
    /// hide that was waiting for the drag.
    func endDragState() {
        dragInProgress = false
        dragPassthrough = false
        stopDragWatchdog()
        // Deferred to the next main-queue turn on purpose: AppKit's in-process drag loop restores the
        // backing window's `ignoresMouseEvents` from a snapshot taken when the drag started, *after*
        // the source's `endedAt` callback. Setting the flag synchronously would let that restore put
        // `ignoresMouseEvents = true` back on a panel that will stay visible (pointer still in the
        // Dock band), and a quick second Dock click would then reach the panel's tiles and launch an
        // app. One turn later the drag loop is gone, so nothing can resurrect it.
        if panel.ignoresMouseEvents {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.dragInProgress else { return }
                self.panel.ignoresMouseEvents = false
            }
        }
        if isShown, panel.alphaValue < 1 {
            let panel = panel
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
    }

    /// Watchdog for a lost drag-end callback: nothing else can clear a click-through panel, so if the
    /// mouse button has been up for `dragWatchdogDelay` while a drag is "in progress", end it here.
    /// 0.5 s ticks in `.common` mode are free; the timer is created at most once per drag.
    func startDragWatchdog() {
        guard dragWatchdog == nil else { return }
        var releasedAt: Date?
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard NSEvent.pressedMouseButtons & 1 == 0 else { releasedAt = nil; return }
                let now = Date()
                let since = releasedAt ?? now
                releasedAt = since
                guard self.dragInProgress,
                      now.timeIntervalSince(since) >= Self.dragWatchdogDelay else { return }
                // Recover as if the drag ended inside the panel: keep it open, but interactable.
                // The session's callbacks stay installed and harmless without a drag.
                self.endDragState()
                self.flushDeferredHide()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragWatchdog = timer
    }

    func stopDragWatchdog() {
        dragWatchdog?.invalidate()
        dragWatchdog = nil
    }
}
