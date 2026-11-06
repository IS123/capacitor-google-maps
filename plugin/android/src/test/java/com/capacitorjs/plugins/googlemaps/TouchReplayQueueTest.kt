package com.capacitorjs.plugins.googlemaps

import android.view.MotionEvent
import com.capacitorjs.plugins.googlemaps.TouchReplayQueue.Target
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class TouchReplayQueueTest {
	private data class FakeEvent(val action: Int, val downTime: Long)

	private val delivered = mutableListOf<Pair<Target, FakeEvent>>()
	private var live = 0
	private lateinit var queue: TouchReplayQueue<FakeEvent>

	@Before
	fun setUp() {
		delivered.clear()
		live = 0
		queue = TouchReplayQueue(
			actionOf = { it.action },
			copy = { live++; it.copy() },
			release = { live-- },
			cancelOf = { live++; it.copy(action = MotionEvent.ACTION_CANCEL) },
		)
	}

	private fun gesture(downTime: Long) = listOf(
		FakeEvent(MotionEvent.ACTION_DOWN, downTime),
		FakeEvent(MotionEvent.ACTION_MOVE, downTime),
		FakeEvent(MotionEvent.ACTION_MOVE, downTime),
		FakeEvent(MotionEvent.ACTION_UP, downTime),
	)

	private fun flush(focus: Boolean) = queue.flush(focus) { target, e -> delivered += target to e }

	/** Every DOWN a target received must be closed by UP/CANCEL before that target's next DOWN. */
	private fun assertBalanced(target: Target) {
		var open: Long? = null
		for ((t, e) in delivered) {
			if (t != target) continue
			when (e.action) {
				MotionEvent.ACTION_DOWN -> {
					assertEquals("$target got DOWN@${e.downTime} while gesture @$open still open: $delivered", null, open)
					open = e.downTime
				}
				MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> open = null
				else -> assertEquals("$target got ${e.action}@${e.downTime} outside its gesture: $delivered", open, e.downTime)
			}
		}
		assertEquals("$target left with gesture @$open never closed: $delivered", null, open)
	}

	@Test
	fun `back-to-back swipes while JS answers lag never leave the WebView with an unterminated gesture`() {
		// AMA-10150: JS answers isMapInFocus late, so new gestures arrive while earlier
		// ones are still queued. Interleave arrivals and flushes the way the device log showed.
		val g1 = gesture(1); val g2 = gesture(2); val g3 = gesture(3)
		queue.enqueue(g1[0]); queue.enqueue(g1[1]); flush(false)
		queue.enqueue(g1[2]); queue.enqueue(g1[3])
		queue.enqueue(g2[0]); flush(false)
		queue.enqueue(g2[1]); queue.enqueue(g2[2]); queue.enqueue(g2[3])
		queue.enqueue(g3[0]); flush(false)
		g3.drop(1).forEach(queue::enqueue); flush(false)

		assertBalanced(Target.WEBVIEW)
		assertEquals(12, delivered.size)
	}

	@Test
	fun `a gesture stays with the target its DOWN went to even if focus flips mid-gesture`() {
		val g = gesture(1)
		queue.enqueue(g[0]); flush(true)
		queue.enqueue(g[1]); flush(false)
		queue.enqueue(g[2]); queue.enqueue(g[3]); flush(false)

		assertTrue(delivered.all { it.first == Target.MAP })
		assertBalanced(Target.MAP)
	}

	@Test
	fun `abandoning mid-gesture cancels the target that already got the DOWN`() {
		val g = gesture(1)
		queue.enqueue(g[0]); queue.enqueue(g[1]); flush(false)
		queue.enqueue(g[2]) // map destroyed before JS answers again
		queue.abandon { target, e -> delivered += target to e }

		assertEquals(Target.WEBVIEW to FakeEvent(MotionEvent.ACTION_CANCEL, 1), delivered.last())
		assertBalanced(Target.WEBVIEW)
		assertEquals("all copies released", 0, live)
	}

	@Test
	fun `a new DOWN arriving while the previous gesture is open cancels the previous one first`() {
		// e.g. the system never delivered the UP of the previous stream.
		val g1 = gesture(1); val g2 = gesture(2)
		queue.enqueue(g1[0]); queue.enqueue(g1[1]); flush(false)
		g2.forEach(queue::enqueue); flush(false)

		assertBalanced(Target.WEBVIEW)
	}

	@Test
	fun `delivered events are released once their gesture ends`() {
		gesture(1).forEach(queue::enqueue); flush(false)
		assertEquals(0, live)
	}
}
