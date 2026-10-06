package com.capacitorjs.plugins.googlemaps

import android.graphics.Bitmap
import android.util.LruCache

class BitmapCache(maxSize: Int) : LruCache<String?, Bitmap>(maxSize) {
    override fun sizeOf(key: String?, bitmap: Bitmap): Int {
        // The cache size will be measured in kilobytes rather than
        // number of items.
        return bitmap.byteCount / 1024
    }

    override fun entryRemoved(
        evicted: Boolean,
        key: String?,
        oldBitmap: Bitmap,
        newBitmap: Bitmap
    ) {
        var oldBitmap: Bitmap? = oldBitmap
        if (!oldBitmap!!.isRecycled) {
            oldBitmap.recycle()
            oldBitmap = null
        }
    }
}
