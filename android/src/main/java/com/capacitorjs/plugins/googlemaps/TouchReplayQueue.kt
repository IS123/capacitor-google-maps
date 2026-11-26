package com.capacitorjs.plugins.googlemaps

import android.view.MotionEvent

/**
 * Touches inside a map's bounds are held here until JS answers `isMapInFocus`, then replayed to
 * the map or the WebView. JS can answer late (slow device, busy main thread), so new gestures
 * keep arriving while earlier ones are still queued.
 *
 * Invariant: every target that received a gesture's DOWN also receives that gesture's UP/CANCEL.
 * A WebView fed DOWN+MOVE without the closing UP keeps its touch-scroll state stuck until the page
 * reloads (AMA-10150), so queued events are never dropped, a gesture stays with the target its DOWN
 * went to, and a gesture that cannot finish is closed with a synthetic CANCEL.
 *
 * Not thread-safe: enqueue, flush and abandon must all run on the main thread.
 */
internal class TouchReplayQueue<E>(
	private val actionOf: (E) -> Int,
	private val copy: (E) -> E,
	private val release: (E) -> Unit,
	private val cancelOf: (E) -> E,
) {
	enum class Target { MAP, WEBVIEW }

	private val pending = ArrayDeque<E>()

	// Target and last delivered event of the gesture currently being replayed (null when none).
	private var openTarget: Target? = null
	private var openLast: E? = null

	fun enqueue(event: E) {
		pending.addLast(copy(event))
	}

	fun flush(focus: Boolean, deliver: (Target, E) -> Unit) {
		while (pending.isNotEmpty()) {
			val event = pending.removeFirst()
			val action = actionOf(event)

			if (action == MotionEvent.ACTION_DOWN) {
				closeOpenGesture(deliver)
				openTarget = if (focus) Target.MAP else Target.WEBVIEW
			}

			val target = openTarget
			if (target == null) {
				// Tail of a gesture whose DOWN was never queued; nobody can make sense of it.
				release(event)
				continue
			}

			deliver(target, event)

			if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
				release(event)
				openLast?.let(release)
				openLast = null
				openTarget = null
			} else {
				openLast?.let(release)
				openLast = event
			}
		}
	}

	/** Drop everything still queued (e.g. the map is being destroyed) and close the open gesture. */
	fun abandon(deliver: (Target, E) -> Unit) {
		pending.forEach(release)
		pending.clear()
		closeOpenGesture(deliver)
	}

	private fun closeOpenGesture(deliver: (Target, E) -> Unit) {
		val target = openTarget ?: return
		val last = openLast
		if (last != null) {
			val cancel = cancelOf(last)
			deliver(target, cancel)
			release(cancel)
			release(last)
		}
		openLast = null
		openTarget = null
	}
}
