package com.capacitorjs.plugins.googlemaps

import android.annotation.SuppressLint
import android.graphics.*
import android.graphics.Bitmap.CompressFormat
import android.location.Location
import android.util.Base64
import android.util.Log
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import com.getcapacitor.Bridge
import com.getcapacitor.JSArray
import com.getcapacitor.JSObject
import com.google.android.gms.maps.*
import com.google.android.gms.maps.GoogleMap.*
import com.google.android.gms.maps.model.*
import com.google.maps.android.clustering.Cluster
import com.google.maps.android.clustering.ClusterManager
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.asFlow
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.flow.toList
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import com.caverock.androidsvg.SVG
import com.getcapacitor.PluginCall
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import org.json.JSONArray
import java.util.concurrent.ConcurrentHashMap

@OptIn(ExperimentalCoroutinesApi::class, FlowPreview::class)
class CapacitorGoogleMap(
    val id: String,
    val config: GoogleMapConfig,
    val delegate: CapacitorGoogleMapsPlugin
) :
    OnCameraIdleListener,
    OnCameraMoveStartedListener,
    OnCameraMoveListener,
    OnMyLocationButtonClickListener,
    OnMyLocationClickListener,
    OnMapReadyCallback,
    OnMapClickListener,
    OnMarkerClickListener,
    OnMarkerDragListener,
    OnInfoWindowClickListener,
    OnCircleClickListener,
    OnPolylineClickListener,
    OnPolygonClickListener,
    OnMapLongClickListener,
    OnMapLoadedCallback {
    private var mapView: MapView
    private var googleMap: GoogleMap? = null
    private val markers = ConcurrentHashMap<String, CapacitorGoogleMapMarker>()
    private val mIds = ConcurrentHashMap<String, String>()
    private val polygons = HashMap<String, CapacitorGoogleMapsPolygon>()
    private val circles = HashMap<String, CapacitorGoogleMapsCircle>()
    private val polylines = HashMap<String, CapacitorGoogleMapPolyline>()
    private val markerIcons = HashMap<String, Bitmap>()
    private var clusterManager: ClusterManager<CapacitorGoogleMapMarker>? = null
    private val markerDispatcher = Executors.newFixedThreadPool(8).asCoroutineDispatcher()
	private val markerUpdates = MutableSharedFlow<List<CapacitorGoogleMapMarker>>(extraBufferCapacity = 1)

    private val isReadyChannel = Channel<Boolean>()
    private var debounceJob: Job? = null
    private var lastZoomLevel: Float = -1f

	private var currentCall: PluginCall? = null

    init {
        val bridge = delegate.bridge

        mapView = MapView(bridge.context, config.googleMapOptions)
        initMap()
        setListeners()

		// Start listening to marker updates reactively
		CoroutineScope(Dispatchers.Main).launch {
			addMarkersReactive(markerUpdates)
				.collect { result ->
					result.onSuccess { ids ->
						val jsonIDs = JSONArray()
						ids.forEach { jsonIDs.put(it) }

						val res = JSObject().apply {
							put("ids", jsonIDs)
						}
						currentCall?.resolve(res)
					}.onFailure { error ->
						currentCall?.reject("Failed to add markers")
					}
				}
		}
    }

    private fun initMap() {
        runBlocking {
            val job =
                CoroutineScope(Dispatchers.Main).launch {
                    mapView.onCreate(null)
                    mapView.onStart()
                    mapView.getMapAsync(this@CapacitorGoogleMap)
                    mapView.setWillNotDraw(false)
                    isReadyChannel.receive()

                    render()
                }

            job.join()
        }
    }

    private fun render() {
        runBlocking {
            CoroutineScope(Dispatchers.Main).launch {
                val bridge = delegate.bridge
                val mapViewParent = FrameLayout(bridge.context)
                mapViewParent.minimumHeight = bridge.webView.height
                mapViewParent.minimumWidth = bridge.webView.width

                val layoutParams =
                    FrameLayout.LayoutParams(
                        getScaledPixels(bridge, config.width),
                        getScaledPixels(bridge, config.height),
                    )
                layoutParams.leftMargin = getScaledPixels(bridge, config.x)
                layoutParams.topMargin = getScaledPixels(bridge, config.y)

                mapViewParent.tag = id

                mapView.layoutParams = layoutParams
                mapViewParent.addView(mapView)

                ((bridge.webView.parent) as ViewGroup).addView(mapViewParent)

                bridge.webView.bringToFront()
                bridge.webView.setBackgroundColor(Color.TRANSPARENT)
                if (config.styles != null) {
                    googleMap?.setMapStyle(MapStyleOptions(config.styles!!))
                }
            }
        }
    }

    fun updateRender(updatedBounds: RectF) {
        this.config.x = updatedBounds.left.toInt()
        this.config.y = updatedBounds.top.toInt()
        this.config.width = updatedBounds.width().toInt()
        this.config.height = updatedBounds.height().toInt()

        runBlocking {
            CoroutineScope(Dispatchers.Main).launch {
                val bridge = delegate.bridge
                val mapRect = getScaledRect(bridge, updatedBounds)
                val mapView = this@CapacitorGoogleMap.mapView;
                mapView.x = mapRect.left
                mapView.y = mapRect.top
                if (mapView.layoutParams.width != config.width || mapView.layoutParams.height != config.height) {
                    mapView.layoutParams.width = getScaledPixels(bridge, config.width)
                    mapView.layoutParams.height = getScaledPixels(bridge, config.height)
                    mapView.requestLayout()
                }
            }
        }
    }

    fun dispatchTouchEvent(event: MotionEvent) {
        CoroutineScope(Dispatchers.Main).launch {
            val offsetViewBounds = getMapBounds()

            val relativeTop = offsetViewBounds.top;
            val relativeLeft = offsetViewBounds.left;

			event.setLocation(event.x - relativeLeft, event.y - relativeTop)
			mapView.dispatchTouchEvent(event)
        }
    }

    fun bringToFront() {
        CoroutineScope(Dispatchers.Main).launch {
            val mapViewParent =
                ((delegate.bridge.webView.parent) as ViewGroup).findViewWithTag<ViewGroup>(
                    this@CapacitorGoogleMap.id
                )
            mapViewParent.bringToFront()
        }
    }

    fun destroy() {
        runBlocking {
            val job =
                CoroutineScope(Dispatchers.Main).launch {
                    val bridge = delegate.bridge

                    val viewToRemove: View? =
                        ((bridge.webView.parent) as ViewGroup).findViewWithTag(id)
                    if (null != viewToRemove) {
                        ((bridge.webView.parent) as ViewGroup).removeView(viewToRemove)
                    }
                    mapView.onDestroy()
                    markerDispatcher.close()
                    googleMap = null
                    clusterManager = null
                }

            job.join()
        }
    }

	fun addMarkers(markers: List<CapacitorGoogleMapMarker>, call: PluginCall) {
		currentCall = call
		markerUpdates.tryEmit(markers)
	}

	@OptIn(ExperimentalCoroutinesApi::class)
	fun addMarkersReactive(
		newMarkersFlow: Flow<List<CapacitorGoogleMapMarker>>
	): Flow<Result<List<String>>> =
		newMarkersFlow
			.flatMapLatest { newMarkers ->
				flow {
					ensureMapAvailable()

					val markerIds = mutableListOf<String>()
					val currentMIds = mutableSetOf<String>()

					// Snapshot current keys in a thread‑safe way
					val existingMIdsSnapshot = mIds.keys.toSet()

					/* ---------- Build / Update ---------- */
					val markersToAdd =
						newMarkers.mapNotNull { marker ->
							currentMIds += marker.mId

							val existingId = mIds[marker.mId]
							if (existingId != null) {
								withContext(Dispatchers.Main) {
									val existingMarker = markers[existingId]
									if (existingMarker != null && existingMarker.iconId != marker.iconId) {
										updateMarkerIcon(
											marker.mId,
											marker.iconId.toString(),
											marker.iconUrl.toString()
										)
									}
									existingMarker?.googleMapMarker?.position = marker.position
								}
								return@mapNotNull null // nothing to add
							} else {
								marker.markerOptions = buildMarker(marker)
								marker
							}
						}

					/* ---------- Apply to GoogleMap (Main thread) ---------- */
					withContext(Dispatchers.Main) {
						markersToAdd.forEach { marker ->
							val googleMapMarker = googleMap?.addMarker(marker.markerOptions!!)
							marker.googleMapMarker = googleMapMarker

							googleMapMarker?.let { gm ->
								// Let clusterManager handle removal if available
								if (clusterManager != null) {
									googleMapMarker.remove()
								}

								mIds[marker.mId] = gm.id
								markers[gm.id] = marker
								markerIds += gm.id
							}
						}

						// Remove markers no longer needed
						val toRemove = existingMIdsSnapshot - currentMIds
						removeMarkersBymId(toRemove.toList()) {
							clusterManager?.apply {
								addItems(markersToAdd)
								cluster()
							}
						}

					}

					emit(Result.success(markerIds))
				}.catch { e ->
					emit(Result.failure(e))
				}.flowOn(markerDispatcher)
			}

	private fun ensureMapAvailable() {
		if (googleMap == null) throw GoogleMapNotAvailable()
	}

    fun addMarker(marker: CapacitorGoogleMapMarker, callback: (result: Result<String>) -> Unit) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()

            var markerId: String

            if (mIds[marker.mId] != null) {
                CoroutineScope(Dispatchers.Main).launch {
                    updateMarkerBymId(marker.mId, marker, callback)
                }
            } else {
                CoroutineScope(Dispatchers.Main).launch {
                    val markerOptions: Deferred<MarkerOptions> =
                        CoroutineScope(Dispatchers.IO).async {
                            this@CapacitorGoogleMap.buildMarker(marker)
                        }
                    val googleMapMarker = googleMap?.addMarker(markerOptions.await())

                    marker.googleMapMarker = googleMapMarker

                    if (clusterManager != null) {
                        googleMapMarker?.remove()
                        clusterManager?.addItem(marker)
                        clusterManager?.cluster()
                    }

                    mIds[marker.mId] = googleMapMarker!!.id

                    markers[googleMapMarker.id] = marker

                    markerId = googleMapMarker.id

                    callback(Result.success(markerId))
                }
            }
        } catch (e: GoogleMapsError) {
            callback(Result.failure(e))
        }
    }

    fun addPolygons(
        newPolygons: List<CapacitorGoogleMapsPolygon>,
        callback: (ids: Result<List<String>>) -> Unit
    ) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()
            val shapeIds: MutableList<String> = mutableListOf()

            CoroutineScope(Dispatchers.Main).launch {
                newPolygons.forEach {
                    val polygonOptions: Deferred<PolygonOptions> =
                        CoroutineScope(Dispatchers.IO).async {
                            this@CapacitorGoogleMap.buildPolygon(it)
                        }

                    val googleMapsPolygon = googleMap?.addPolygon(polygonOptions.await())
                    googleMapsPolygon?.tag = it.tag

                    it.googleMapsPolygon = googleMapsPolygon

                    polygons[googleMapsPolygon!!.id] = it
                    shapeIds.add(googleMapsPolygon.id)
                }

                callback(Result.success(shapeIds))
            }
        } catch (e: GoogleMapsError) {
            callback(Result.failure(e))
        }
    }

    fun addCircles(
        newCircles: List<CapacitorGoogleMapsCircle>,
        callback: (ids: Result<List<String>>) -> Unit
    ) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()
            val circleIds: MutableList<String> = mutableListOf()

            CoroutineScope(Dispatchers.Main).launch {
                newCircles.forEach {
                    var circleOptions: Deferred<CircleOptions> =
                        CoroutineScope(Dispatchers.IO).async {
                            this@CapacitorGoogleMap.buildCircle(it)
                        }

                    val googleMapsCircle = googleMap?.addCircle(circleOptions.await())
                    googleMapsCircle?.tag = it.tag

                    it.googleMapsCircle = googleMapsCircle

                    circles[googleMapsCircle!!.id] = it
                    circleIds.add(googleMapsCircle.id)
                }

                callback(Result.success(circleIds))
            }
        } catch (e: GoogleMapsError) {
            callback(Result.failure(e))
        }
    }

    fun addPolylines(
        newLines: List<CapacitorGoogleMapPolyline>,
        callback: (ids: Result<List<String>>) -> Unit
    ) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()
            val lineIds: MutableList<String> = mutableListOf()

            CoroutineScope(Dispatchers.Main).launch {
                newLines.forEach {
                    val polylineOptions: Deferred<PolylineOptions> =
                        CoroutineScope(Dispatchers.IO).async {
                            this@CapacitorGoogleMap.buildPolyline(it)
                        }
                    val googleMapPolyline = googleMap?.addPolyline(polylineOptions.await())
                    googleMapPolyline?.tag = it.tag

                    it.googleMapsPolyline = googleMapPolyline

                    polylines[googleMapPolyline!!.id] = it
                    lineIds.add(googleMapPolyline.id)
                }

                callback(Result.success(lineIds))
            }
        } catch (e: GoogleMapsError) {
            callback(Result.failure(e))
        }
    }

    private fun setClusterManagerRenderer(minClusterSize: Int?) {
        clusterManager?.renderer = CapacitorClusterManagerRenderer(
            delegate.bridge.context,
            googleMap,
            clusterManager,
            minClusterSize
        )
    }

    @SuppressLint("PotentialBehaviorOverride")
    fun enableClustering(minClusterSize: Int?, callback: (error: GoogleMapsError?) -> Unit) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()

            CoroutineScope(Dispatchers.Main).launch {
                if (clusterManager != null) {
                    setClusterManagerRenderer(minClusterSize)
                    callback(null)
                    return@launch
                }

                val bridge = delegate.bridge
                clusterManager = ClusterManager(bridge.context, googleMap)

                setClusterManagerRenderer(minClusterSize)
                setClusterListeners()

                // add existing markers to the cluster
                if (markers.isNotEmpty()) {
                    val copyMap = HashMap(markers);
                    for ((_, marker) in copyMap) {
                        marker.googleMapMarker?.remove()
                        // marker.googleMapMarker = null
                    }
                    clusterManager?.addItems(markers.values)
                    clusterManager?.cluster()
                }

                callback(null)
            }
        } catch (e: GoogleMapsError) {
            callback(e)
        }
    }

    @SuppressLint("PotentialBehaviorOverride")
    fun disableClustering(callback: (error: GoogleMapsError?) -> Unit) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()

            CoroutineScope(Dispatchers.Main).launch {
                clusterManager?.clearItems()
                clusterManager?.cluster()
                clusterManager = null

                googleMap?.setOnMarkerClickListener(this@CapacitorGoogleMap)

                // add existing markers back to the map
                if (markers.isNotEmpty()) {
                    val copyMap = HashMap(markers);
                    for ((_, marker) in copyMap) {
                        val markerOptions: Deferred<MarkerOptions> =
                            CoroutineScope(Dispatchers.IO).async {
                                this@CapacitorGoogleMap.buildMarker(marker)
                            }
                        val googleMapMarker = googleMap?.addMarker(markerOptions.await())
                        marker.googleMapMarker = googleMapMarker
                    }
                }

                callback(null)
            }
        } catch (e: GoogleMapsError) {
            callback(e)
        }
    }

    fun removePolygons(ids: List<String>, callback: (error: GoogleMapsError?) -> Unit) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()

            CoroutineScope(Dispatchers.Main).launch {
                ids.forEach {
                    val polygon = polygons[it]
                    if (polygon != null) {
                        polygon.googleMapsPolygon?.remove()
                        polygons.remove(it)
                    }
                }

                callback(null)
            }
        } catch (e: GoogleMapsError) {
            callback(e)
        }
    }

    fun removeMarkerBymId(mId: String, callback: (error: GoogleMapsError?) -> Unit) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()

            val marker = markers[mIds[mId]];
            marker ?: throw MarkerNotFoundError()

            CoroutineScope(Dispatchers.Main).launch {
                if (clusterManager != null) {
                    clusterManager?.removeItem(marker)
                    clusterManager?.cluster()
                }

                marker.googleMapMarker?.remove()
                mIds.remove(mId)
                markers.remove(mIds[mId])

                callback(null)
            }
        } catch (e: GoogleMapsError) {
            callback(e)
        }
    }

    fun removeMarker(id: String, callback: (error: GoogleMapsError?) -> Unit) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()

            val marker = markers[id]
            marker ?: throw MarkerNotFoundError()

            CoroutineScope(Dispatchers.Main).launch {
                if (clusterManager != null) {
                    clusterManager?.removeItem(marker)
                    clusterManager?.cluster()
                }

                marker.googleMapMarker?.remove()
                markers.remove(id)

                callback(null)
            }
        } catch (e: GoogleMapsError) {
            callback(e)
        }
    }

    fun removeMarkersBymId(ids: List<String>, callback: (error: GoogleMapsError?) -> Unit) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()

            CoroutineScope(Dispatchers.Main).launch {
                val deletedMarkers: MutableList<CapacitorGoogleMapMarker> = mutableListOf()

                ids.forEach {
                    val marker = markers[mIds[it]]
                    if (marker != null) {
                        marker.googleMapMarker?.remove()
                        markers.remove(mIds[it])
                        mIds.remove(it)

                        deletedMarkers.add(marker)
                    }
                }

                if (clusterManager != null) {
                    clusterManager?.removeItems(deletedMarkers)
                    clusterManager?.cluster()
                }

                callback(null)
            }
        } catch (e: GoogleMapsError) {
            callback(e)
        }
    }

    fun removeMarkers(ids: List<String>, callback: (error: GoogleMapsError?) -> Unit) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()

            CoroutineScope(Dispatchers.Main).launch {
                val deletedMarkers: MutableList<CapacitorGoogleMapMarker> = mutableListOf()

                ids.forEach {
                    val marker = markers[it]
                    if (marker != null) {
                        marker.googleMapMarker?.remove()
                        markers.remove(it)

                        deletedMarkers.add(marker)
                    }
                }

                if (clusterManager != null) {
                    clusterManager?.removeItems(deletedMarkers)
                    clusterManager?.cluster()
                }

                callback(null)
            }
        } catch (e: GoogleMapsError) {
            callback(e)
        }
    }

    fun removeCircles(ids: List<String>, callback: (error: GoogleMapsError?) -> Unit) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()

            CoroutineScope(Dispatchers.Main).launch {
                ids.forEach {
                    val circle = circles[it]
                    if (circle != null) {
                        circle.googleMapsCircle?.remove()
                        markers.remove(it)
                    }
                }

                callback(null)
            }
        } catch (e: GoogleMapsError) {
            callback(e)
        }
    }

    fun removePolylines(ids: List<String>, callback: (error: GoogleMapsError?) -> Unit) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()

            CoroutineScope(Dispatchers.Main).launch {
                ids.forEach {
                    val polyline = polylines[it]
                    if (polyline != null) {
                        polyline.googleMapsPolyline?.remove()
                        polylines.remove(it)
                    }
                }

                callback(null)
            }
        } catch (e: GoogleMapsError) {
            callback(e)
        }
    }

    fun updateMarker(id: String, marker: CapacitorGoogleMapMarker, callback: (result: Result<String>) -> Unit) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()

            this.removeMarker(id) { err ->
                if (err != null) {
                    throw err
                }

                this.addMarker(marker, callback);
            }

        } catch (e: GoogleMapsError) {
        }
    }

    fun updateMarkerBymId(mId: String, marker: CapacitorGoogleMapMarker, callback: (result: Result<String>) -> Unit) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()

            mIds[mId]?.let {
                this.removeMarker(it) { err ->
                    if (err != null) {
                        throw err
                    }

                    this.addMarker(marker, callback);
                }
            }

        } catch (e: GoogleMapsError) {
        }
    }

    fun updateMarkersBymId(ids: List<String>, markers: List<CapacitorGoogleMapMarker>, callback: (result: List<String>) -> Unit) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()

            val res: MutableList<String> = mutableListOf()

            ids.forEach { it ->
                val id = it;
                markers.find { it.mId == id }?.let { it1 -> this.updateMarkerBymId(id, it1) {
                    result -> res.add(result.getOrThrow())
                } }
            }

            callback(res)
        } catch (e: GoogleMapsError) {
        }
    }

    fun updateMarkerIcon(mId: String, iconId: String, iconUrl: String) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()

            val markerId = mIds[mId] ?: throw MarkerNotFoundError("No marker ID found for mId: $mId")
            val marker = markers[markerId] ?: throw MarkerNotFoundError("No marker object for markerId: $markerId")

            if (iconId.isNotEmpty()) {
                if (this.markerIcons.contains(iconId)) {
                    val cachedBitmap = this.markerIcons[iconId]
                    marker.googleMapMarker?.setIcon(cachedBitmap?.let { getResizedIcon(it, marker) })
                } else {
                    val base64Data = iconUrl.substringAfter("base64,", "")

                    if (marker.iconUrl?.startsWith("data:image/svg+xml") == true) {
                        if (base64Data.isNotEmpty()) {
                            val bitmap = svgBase64ToBitmap(base64Data, marker.iconSize!!.width, marker.iconSize!!.height)
                            if (bitmap != null) {
                                this.markerIcons[marker.iconId!!] = bitmap
                                marker.googleMapMarker?.setIcon(getResizedIcon(bitmap, marker))
                            } else {
                                Log.w("CapacitorGoogleMaps", "Failed to decode SVG icon for mId=${marker.mId}, iconId=${marker.iconId}")
                            }
                        } else {
                            Log.w("CapacitorGoogleMaps", "Invalid Base64 SVG data for marker: ${marker.iconUrl}")
                        }
                    } else {
                        if (base64Data.isNotEmpty()) {
                            val decodedString = Base64.decode(base64Data, Base64.DEFAULT)
                            val bitmap = BitmapFactory.decodeByteArray(decodedString, 0, decodedString.size)
                            if (marker.iconId.toBoolean()) {
                                this.markerIcons[marker.iconId!!] = bitmap
                                marker.googleMapMarker?.setIcon(getResizedIcon(bitmap, marker))
                            }

                        } else {
                            Log.w("CapacitorGoogleMaps", "Invalid Base64 bitmap data for marker: ${marker.iconUrl}")
                        }
                    }
                }
            }
        } catch (e: GoogleMapsError) {
            Log.e("CapacitorGoogleMaps", "GoogleMapsError in updateMarkerIcon", e)
        } catch (e: Exception) {
            Log.e("CapacitorGoogleMaps", "Unexpected error in updateMarkerIcon", e)
        }
    }

    fun getMarkersIds(callback: (ids: Result<ConcurrentHashMap<String, String>>?) -> Unit) {
        try {
            callback(Result.success(mIds))
        } catch (e: GoogleMapsError) {
            callback(null)
        }
    }

    fun takeSnapshot(
		format: CompressFormat,
		quality: Int,
		callback: (result: String, error: GoogleMapsError?) -> Unit
	) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()

            googleMap!!.snapshot { bitmap ->
                try {
                    if (bitmap !== null) {
                        val base64Image = bitmapToBase64(bitmap, format, quality)
                        callback(base64Image, null)
                    }
                } catch (e: GoogleMapsError) {
                    callback("", e)
                }
            }

        } catch (e: GoogleMapsError) {
            callback("", e)
        }
    }

    private fun bitmapToBase64(bitmap: Bitmap, format: Bitmap.CompressFormat = Bitmap.CompressFormat.PNG, quality: Int = 100): String {
        val outputStream = ByteArrayOutputStream()
        bitmap.compress(format, quality, outputStream)
        val byteArray = outputStream.toByteArray()
        return Base64.encodeToString(byteArray, Base64.NO_WRAP)
    }

    fun addGroundOverlay(
        latitude: Double,
        longitude: Double,
        width: Float,
        height: Float,
        imagePath: String,
        onComplete: (() -> Unit)? = null
    ) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()

            val position = LatLng(latitude, longitude)

            val pl = CapacitorGoogleMapsGroundOverlay(delegate.bridge)

            val callback = PluginAsync(
                onPostExecuteFunc = { result ->
                    if (result == null) {
                        //callbackContext.error("Cannot create a ground overlay")
                        //return
                        println("Error: result NULL")
                    } else {
                        try {
                            val bitmapDescriptor = BitmapDescriptorFactory.fromBitmap(result.image)
                            val groundOverlayOptions =
                                GroundOverlayOptions().image(bitmapDescriptor)
                                    .position(position, result.image.width.toFloat(), result.image.height.toFloat())
                            googleMap!!.addGroundOverlay(groundOverlayOptions)
                        } catch (e: java.lang.Exception) {
                            Log.e("CapacitorGoogleMaps", e.stackTraceToString())
                        } finally {
                            onComplete?.invoke()
                        }
                    }
                },
                onErrorFunc = { errorMsg ->
                    if (errorMsg != null) {
                        println("Error: $errorMsg")
                    } else {
                        println("Unknown error occurred.")
                    }
                }
            )

            pl.setImage_(imagePath, callback)

        } catch (e: GoogleMapsError) {
        }
    }

    fun getZoomLevel(callback: (zoomLevel: Float?) -> Unit) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()

            callback(googleMap?.cameraPosition?.zoom)

        } catch (e: GoogleMapsError) {
        }
    }

    fun hasIcon(iconId: String): Boolean {
        return this@CapacitorGoogleMap.markerIcons.contains(iconId);
    }

    fun setCamera(config: GoogleMapCameraConfig, callback: (error: GoogleMapsError?) -> Unit) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()
            CoroutineScope(Dispatchers.Main).launch {
                val currentPosition = googleMap!!.cameraPosition

                var updatedTarget = config.coordinate
                if (updatedTarget == null) {
                    updatedTarget = currentPosition.target
                }

                var zoom = config.zoom
                if (zoom == null) {
                    zoom = currentPosition.zoom.toDouble()
                }

                var bearing = config.bearing
                if (bearing == null) {
                    bearing = currentPosition.bearing.toDouble()
                }

                var angle = config.angle
                if (angle == null) {
                    angle = currentPosition.tilt.toDouble()
                }

                var animate = config.animate
                if (animate == null) {
                    animate = false
                }

                val updatedPosition =
                    CameraPosition.Builder()
                        .target(updatedTarget)
                        .zoom(zoom.toFloat())
                        .bearing(bearing.toFloat())
                        .tilt(angle.toFloat())
                        .build()

                if (animate) {
                    googleMap?.animateCamera(CameraUpdateFactory.newCameraPosition(updatedPosition))
                } else {
                    googleMap?.moveCamera(CameraUpdateFactory.newCameraPosition(updatedPosition))
                }
                callback(null)
            }
        } catch (e: GoogleMapsError) {
            callback(e)
        }
    }

    fun getMapType(callback: (type: String, error: GoogleMapsError?) -> Unit) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()
            CoroutineScope(Dispatchers.Main).launch {
                val mapType: String = when (googleMap?.mapType) {
                    MAP_TYPE_NORMAL -> "Normal"
                    MAP_TYPE_HYBRID -> "Hybrid"
                    MAP_TYPE_SATELLITE -> "Satellite"
                    MAP_TYPE_TERRAIN -> "Terrain"
                    MAP_TYPE_NONE -> "None"
                    else -> {
                        "Normal"
                    }
                }
                callback(mapType, null);
            }
        } catch (e: GoogleMapsError) {
            callback("", e)
        }
    }

    fun setMapType(mapType: String, callback: (error: GoogleMapsError?) -> Unit) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()
            CoroutineScope(Dispatchers.Main).launch {
                val mapTypeInt: Int =
                    when (mapType) {
                        "Normal" -> MAP_TYPE_NORMAL
                        "Hybrid" -> MAP_TYPE_HYBRID
                        "Satellite" -> MAP_TYPE_SATELLITE
                        "Terrain" -> MAP_TYPE_TERRAIN
                        "None" -> MAP_TYPE_NONE
                        else -> {
                            Log.w(
                                "CapacitorGoogleMaps",
                                "unknown mapView type '$mapType'  Defaulting to normal."
                            )
                            MAP_TYPE_NORMAL
                        }
                    }

                googleMap?.mapType = mapTypeInt
                callback(null)
            }
        } catch (e: GoogleMapsError) {
            callback(e)
        }
    }

    fun enableIndoorMaps(enabled: Boolean, callback: (error: GoogleMapsError?) -> Unit) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()
            CoroutineScope(Dispatchers.Main).launch {
                googleMap?.isIndoorEnabled = enabled
                callback(null)
            }
        } catch (e: GoogleMapsError) {
            callback(e)
        }
    }

    fun enableTrafficLayer(enabled: Boolean, callback: (error: GoogleMapsError?) -> Unit) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()
            CoroutineScope(Dispatchers.Main).launch {
                googleMap?.isTrafficEnabled = enabled
                callback(null)
            }
        } catch (e: GoogleMapsError) {
            callback(e)
        }
    }

    @SuppressLint("MissingPermission")
    fun enableCurrentLocation(enabled: Boolean, callback: (error: GoogleMapsError?) -> Unit) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()
            CoroutineScope(Dispatchers.Main).launch {
                googleMap?.isMyLocationEnabled = enabled
                callback(null)
            }
        } catch (e: GoogleMapsError) {
            callback(e)
        }
    }

    fun setPadding(padding: GoogleMapPadding, callback: (error: GoogleMapsError?) -> Unit) {
        try {
            googleMap ?: throw GoogleMapNotAvailable()
            CoroutineScope(Dispatchers.Main).launch {
                googleMap?.setPadding(padding.left, padding.top, padding.right, padding.bottom)
                callback(null)
            }
        } catch (e: GoogleMapsError) {
            callback(e)
        }
    }

    fun getMapBounds(): Rect {
        return Rect(
            getScaledPixels(delegate.bridge, config.x),
            getScaledPixels(delegate.bridge, config.y),
            getScaledPixels(delegate.bridge, config.x + config.width),
            getScaledPixels(delegate.bridge, config.y + config.height)
        )
    }

    fun getLatLngBounds(): LatLngBounds {
        return googleMap?.projection?.visibleRegion?.latLngBounds ?: throw BoundsNotFoundError()
    }

    fun fitBounds(bounds: LatLngBounds, padding: Int) {
        val cameraUpdate = CameraUpdateFactory.newLatLngBounds(bounds, padding)
        googleMap?.animateCamera(cameraUpdate)
    }

    private fun getScaledPixels(bridge: Bridge, pixels: Int): Int {
        // Get the screen's density scale
        val scale = bridge.activity.resources.displayMetrics.density
        // Convert the dps to pixels, based on density scale
        return (pixels * scale + 0.5f).toInt()
    }

    private fun getScaledPixelsF(bridge: Bridge, pixels: Float): Float {
        // Get the screen's density scale
        val scale = bridge.activity.resources.displayMetrics.density
        // Convert the dps to pixels, based on density scale
        return (pixels * scale + 0.5f)
    }

    private fun getScaledRect(bridge: Bridge, rectF: RectF): RectF {
        return RectF(
            getScaledPixelsF(bridge, rectF.left),
            getScaledPixelsF(bridge, rectF.top),
            getScaledPixelsF(bridge, rectF.right),
            getScaledPixelsF(bridge, rectF.bottom)
        )
    }

    private fun buildCircle(circle: CapacitorGoogleMapsCircle): CircleOptions {
        val circleOptions = CircleOptions()
        circleOptions.fillColor(circle.fillColor)
        circleOptions.strokeColor(circle.strokeColor)
        circleOptions.strokeWidth(circle.strokeWidth)
        circleOptions.zIndex(circle.zIndex)
        circleOptions.clickable(circle.clickable)
        circleOptions.radius(circle.radius.toDouble())
        circleOptions.center(circle.center)

        return circleOptions
    }

    private fun buildPolygon(polygon: CapacitorGoogleMapsPolygon): PolygonOptions {
        val polygonOptions = PolygonOptions()
        polygonOptions.fillColor(polygon.fillColor)
        polygonOptions.strokeColor(polygon.strokeColor)
        polygonOptions.strokeWidth(polygon.strokeWidth)
        polygonOptions.zIndex(polygon.zIndex)
        polygonOptions.geodesic(polygon.geodesic)
        polygonOptions.clickable(polygon.clickable)

        var shapeCounter = 0
        polygon.shapes.forEach {
            if (shapeCounter == 0) {
                // outer shape
                it.forEach {
                    polygonOptions.add(it)
                }
            } else {
                polygonOptions.addHole(it)
            }

            shapeCounter += 1
        }

        return polygonOptions
    }

    private fun buildPolyline(line: CapacitorGoogleMapPolyline): PolylineOptions {
        val polylineOptions = PolylineOptions()
        polylineOptions.width(line.strokeWidth * this.config.devicePixelRatio)
        polylineOptions.color(line.strokeColor)
        polylineOptions.clickable(line.clickable)
        polylineOptions.zIndex(line.zIndex)
        polylineOptions.geodesic(line.geodesic)

        line.path.forEach {
            polylineOptions.add(it)
        }

        line.styleSpans.forEach {
            if (it.segments != null) {
                polylineOptions.addSpan(StyleSpan(it.color, it.segments))
            } else {
                polylineOptions.addSpan(StyleSpan(it.color))
            }
        }

        return polylineOptions
    }

    fun svgBase64ToBitmap(base64Svg: String, width: Int, height: Int): Bitmap? {
        return try {
            val decodedBytes = Base64.decode(base64Svg, Base64.DEFAULT)
            val svgString = String(decodedBytes, Charsets.UTF_8)

            val svg = SVG.getFromString(svgString)
            svg.setDocumentWidth("100%")
            svg.setDocumentHeight("100%")

            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)

            svg.renderToCanvas(canvas)
            bitmap
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }

    private fun buildMarker(marker: CapacitorGoogleMapMarker): MarkerOptions {
        val markerOptions = MarkerOptions()
        markerOptions.position(marker.coordinate)
        markerOptions.title(marker.title)
        markerOptions.snippet(marker.snippet)
        markerOptions.alpha(marker.opacity)
        markerOptions.flat(marker.isFlat)
        markerOptions.draggable(marker.draggable)
        markerOptions.zIndex(marker.zIndex)

        if (marker.iconAnchor != null) {
            markerOptions.anchor(marker.iconAnchor!!.x, marker.iconAnchor!!.y)
        }

        // Check if there's an icon URL (assumed to be a Data URL in this case)
        if (!marker.iconId.isNullOrEmpty()) {
            if (this.markerIcons.contains(marker.iconId)) {
                val cachedBitmap = this.markerIcons[marker.iconId]
                markerOptions.icon(getResizedIcon(cachedBitmap!!, marker))
            } else {
                try {
                    val base64Data = marker.iconUrl!!.substringAfter("base64,", "")

                    if (marker.iconUrl!!.startsWith("data:image/svg+xml")) {
                        if (base64Data.isNotEmpty()) {
                            val bitmap = svgBase64ToBitmap(base64Data, marker.iconSize!!.width, marker.iconSize!!.height)
                            this.markerIcons[marker.iconId!!] = bitmap as Bitmap
                            markerOptions.icon(getResizedIcon(bitmap, marker))
                        } else {
                            Log.w(
                                "CapacitorGoogleMaps",
                                "Invalid Base64 data URL: ${marker.iconUrl}. Using default marker icon."
                            )
                        }
                    } else {
                        // Check if Data URL has a valid base64 part
                        if (base64Data.isNotEmpty()) {
                            // Decode the Base64 string into a Bitmap
                            val decodedString = Base64.decode(base64Data, Base64.DEFAULT)
                            val bitmap =
                                BitmapFactory.decodeByteArray(decodedString, 0, decodedString.size)

                            // Cache the bitmap for future use
                            this.markerIcons[marker.iconId!!] = bitmap
                            markerOptions.icon(getResizedIcon(bitmap, marker))
                        } else {
                            Log.w(
                                "CapacitorGoogleMaps",
                                "Invalid Base64 data URL: ${marker.iconUrl}. Using default marker icon."
                            )
                        }
                    }

                } catch (e: Exception) {
                    val detailedMessage = "${e.javaClass} - ${e.localizedMessage}"
                    Log.w(
                        "CapacitorGoogleMaps",
                        "Could not decode Base64 image: ${detailedMessage}. Using default marker icon."
                    )
                }
            }
        } else {
            // Fallback to color marker if no icon URL is provided
            if (marker.colorHue != null) {
                markerOptions.icon(BitmapDescriptorFactory.defaultMarker(marker.colorHue!!))
            }
        }

        marker.markerOptions = markerOptions
        return markerOptions
    }

    private fun getResizedIcon(
        _bitmap: Bitmap,
        marker: CapacitorGoogleMapMarker
    ): BitmapDescriptor {
        var bitmap = _bitmap
        if (marker.iconSize != null) {
            bitmap =
                Bitmap.createScaledBitmap(
                    bitmap,
                    (marker.iconSize!!.width * this.config.devicePixelRatio).toInt(),
                    (marker.iconSize!!.height * this.config.devicePixelRatio).toInt(),
                    false
                )
        }
        return BitmapDescriptorFactory.fromBitmap(bitmap)
    }

    fun onStart() {
        mapView.onStart()
    }

    fun onResume() {
        mapView.onResume()
    }

    fun onStop() {
        mapView.onStop()
    }

    fun onPause() {
        mapView.onPause()
    }

    fun onDestroy() {
        mapView.onDestroy()
    }

    override fun onMapReady(map: GoogleMap) {
        runBlocking {
            googleMap = map

            val data = JSObject()
            data.put("mapId", this@CapacitorGoogleMap.id)
            delegate.notify("onMapReady", data)

            isReadyChannel.send(true)
            isReadyChannel.close()
        }
    }

    @SuppressLint("PotentialBehaviorOverride")
    fun setListeners() {
        CoroutineScope(Dispatchers.Main).launch {
            this@CapacitorGoogleMap.googleMap?.setOnCameraIdleListener(this@CapacitorGoogleMap)
            this@CapacitorGoogleMap.googleMap?.setOnCameraMoveStartedListener(
                this@CapacitorGoogleMap
            )
            this@CapacitorGoogleMap.googleMap?.setOnCameraMoveListener(this@CapacitorGoogleMap)
            this@CapacitorGoogleMap.googleMap?.setOnMarkerClickListener(this@CapacitorGoogleMap)
            this@CapacitorGoogleMap.googleMap?.setOnPolygonClickListener(this@CapacitorGoogleMap)
            this@CapacitorGoogleMap.googleMap?.setOnCircleClickListener(this@CapacitorGoogleMap)
            this@CapacitorGoogleMap.googleMap?.setOnMarkerDragListener(this@CapacitorGoogleMap)
            this@CapacitorGoogleMap.googleMap?.setOnMapClickListener(this@CapacitorGoogleMap)
            this@CapacitorGoogleMap.googleMap?.setOnMyLocationButtonClickListener(
                this@CapacitorGoogleMap
            )
            this@CapacitorGoogleMap.googleMap?.setOnMyLocationClickListener(this@CapacitorGoogleMap)
            this@CapacitorGoogleMap.googleMap?.setOnInfoWindowClickListener(this@CapacitorGoogleMap)
            this@CapacitorGoogleMap.googleMap?.setOnPolylineClickListener(this@CapacitorGoogleMap)
            this@CapacitorGoogleMap.googleMap?.setOnMapLongClickListener(this@CapacitorGoogleMap)
            this@CapacitorGoogleMap.googleMap?.setOnMapLoadedCallback(this@CapacitorGoogleMap)
        }
    }

    fun setClusterListeners() {
        CoroutineScope(Dispatchers.Main).launch {
            clusterManager?.setOnClusterItemClickListener {
                if (null == it.googleMapMarker) false
                else this@CapacitorGoogleMap.onMarkerClick(it.googleMapMarker!!)
            }

            clusterManager?.setOnClusterItemInfoWindowClickListener {
                if (null != it.googleMapMarker) {
                    this@CapacitorGoogleMap.onInfoWindowClick(it.googleMapMarker!!)
                }
            }

            clusterManager?.setOnClusterInfoWindowClickListener {
                val data = this@CapacitorGoogleMap.getClusterData(it)
                delegate.notify("onClusterInfoWindowClick", data)
            }

            clusterManager?.setOnClusterClickListener {
                val data = this@CapacitorGoogleMap.getClusterData(it)
                delegate.notify("onClusterClick", data)
                false
            }
        }
    }

    private fun getClusterData(it: Cluster<CapacitorGoogleMapMarker>): JSObject {
        val data = JSObject()
        data.put("mapId", this.id)
        data.put("latitude", it.position.latitude)
        data.put("longitude", it.position.longitude)
        data.put("size", it.size)

        val items = JSArray()
        for (item in it.items) {
            val marker = item.googleMapMarker

            if (marker != null) {
                val jsItem = JSObject()
                jsItem.put("markerId", marker.id)
                jsItem.put("latitude", marker.position.latitude)
                jsItem.put("longitude", marker.position.longitude)
                jsItem.put("title", marker.title)
                jsItem.put("snippet", marker.snippet)

                items.put(jsItem)
            }
        }

        data.put("items", items)

        return data
    }

    override fun onMapClick(point: LatLng) {
        val data = JSObject()
        data.put("mapId", this@CapacitorGoogleMap.id)
        data.put("latitude", point.latitude)
        data.put("longitude", point.longitude)
        delegate.notify("onMapClick", data)
    }

    override fun onMarkerClick(marker: Marker): Boolean {
        val data = JSObject()
        data.put("mapId", this@CapacitorGoogleMap.id)
        data.put("mId", mIds.entries.find { it.value == marker.id }?.key)
        data.put("markerId", marker.id)
        data.put("latitude", marker.position.latitude)
        data.put("longitude", marker.position.longitude)
        data.put("title", marker.title)
        data.put("snippet", marker.snippet)
        delegate.notify("onMarkerClick", data)
        return false
    }

    override fun onPolylineClick(polyline: Polyline) {
        val data = JSObject()
        data.put("mapId", this@CapacitorGoogleMap.id)
        data.put("polylineId", polyline.id)
        data.put("tag", polyline.tag)
        delegate.notify("onPolylineClick", data)
    }

    override fun onMarkerDrag(marker: Marker) {
        val data = JSObject()
        data.put("mapId", this@CapacitorGoogleMap.id)
        data.put("mId", mIds.entries.find { it.value == marker.id }?.key )
        data.put("markerId", marker.id)
        data.put("latitude", marker.position.latitude)
        data.put("longitude", marker.position.longitude)
        data.put("title", marker.title)
        data.put("snippet", marker.snippet)
        delegate.notify("onMarkerDrag", data)
    }

    override fun onMarkerDragStart(marker: Marker) {
        val data = JSObject()
        data.put("mapId", this@CapacitorGoogleMap.id)
        data.put("mId", mIds.entries.find { it.value == marker.id }?.key )
        data.put("markerId", marker.id)
        data.put("latitude", marker.position.latitude)
        data.put("longitude", marker.position.longitude)
        data.put("title", marker.title)
        data.put("snippet", marker.snippet)
        delegate.notify("onMarkerDragStart", data)
    }

    override fun onMarkerDragEnd(marker: Marker) {
        val data = JSObject()
        data.put("mapId", this@CapacitorGoogleMap.id)
        data.put("mId", mIds.entries.find { it.value == marker.id }?.key )
        data.put("markerId", marker.id)
        data.put("latitude", marker.position.latitude)
        data.put("longitude", marker.position.longitude)
        data.put("title", marker.title)
        data.put("snippet", marker.snippet)
        delegate.notify("onMarkerDragEnd", data)
    }

    override fun onMyLocationButtonClick(): Boolean {
        val data = JSObject()
        data.put("mapId", this@CapacitorGoogleMap.id)
        delegate.notify("onMyLocationButtonClick", data)
        return false
    }

    override fun onMyLocationClick(location: Location) {
        val data = JSObject()
        data.put("mapId", this@CapacitorGoogleMap.id)
        data.put("latitude", location.latitude)
        data.put("longitude", location.longitude)
        delegate.notify("onMyLocationClick", data)
    }

    override fun onCameraIdle() {
        val data = JSObject()
        data.put("mapId", this@CapacitorGoogleMap.id)
        data.put("bounds", getLatLngBoundsJSObject(getLatLngBounds()))
        data.put("bearing", this@CapacitorGoogleMap.googleMap?.cameraPosition?.bearing)
        data.put("latitude", this@CapacitorGoogleMap.googleMap?.cameraPosition?.target?.latitude)
        data.put("longitude", this@CapacitorGoogleMap.googleMap?.cameraPosition?.target?.longitude)
        data.put("tilt", this@CapacitorGoogleMap.googleMap?.cameraPosition?.tilt)
        data.put("zoom", this@CapacitorGoogleMap.googleMap?.cameraPosition?.zoom)
        delegate.notify("onCameraIdle", data)
        delegate.notify("onBoundsChanged", data)
        val currentZoomLevel = googleMap?.cameraPosition?.zoom
        if (currentZoomLevel != null && currentZoomLevel != lastZoomLevel) {
            lastZoomLevel = currentZoomLevel
            delegate.notify("onZoomChanged", JSObject().put("zoomLevel", lastZoomLevel))
        }
    }

    override fun onCameraMoveStarted(reason: Int) {
        val data = JSObject()
        data.put("mapId", this@CapacitorGoogleMap.id)
        data.put("isGesture", reason == 1)
        delegate.notify("onCameraMoveStarted", data)
    }

    override fun onInfoWindowClick(marker: Marker) {
        val data = JSObject()
        data.put("mapId", this@CapacitorGoogleMap.id)
        data.put("markerId", marker.id)
        data.put("latitude", marker.position.latitude)
        data.put("longitude", marker.position.longitude)
        data.put("title", marker.title)
        data.put("snippet", marker.snippet)
        delegate.notify("onInfoWindowClick", data)
    }

    override fun onCameraMove() {
        debounceJob?.cancel()
        debounceJob = CoroutineScope(Dispatchers.Main).launch {
            delay(100)
            clusterManager?.cluster()
        }
    }

    override fun onPolygonClick(polygon: Polygon) {
        val data = JSObject()
        data.put("mapId", this@CapacitorGoogleMap.id)
        data.put("polygonId", polygon.id)
        data.put("tag", polygon.tag)
        delegate.notify("onPolygonClick", data)
    }

    override fun onCircleClick(circle: Circle) {
        val data = JSObject()
        data.put("mapId", this@CapacitorGoogleMap.id)
        data.put("circleId", circle.id)
        data.put("tag", circle.tag)
        data.put("latitude", circle.center.latitude)
        data.put("longitude", circle.center.longitude)
        data.put("radius", circle.radius)

        delegate.notify("onCircleClick", data)
    }

    override fun onMapLongClick(point: LatLng) {
        val data = JSObject()
        data.put("mapId", this@CapacitorGoogleMap.id)
        data.put("latitude", point.latitude)
        data.put("longitude", point.longitude)
        delegate.notify("onMapLongClick", data)
    }

    override fun onMapLoaded() {
        val data = JSObject()
        data.put("mapId", this@CapacitorGoogleMap.id)
        delegate.notify("onMapLoaded", data)
    }
}

fun getLatLngBoundsJSObject(bounds: LatLngBounds): JSObject {
    val data = JSObject()

    val southwestJS = JSObject()
    val centerJS = JSObject()
    val northeastJS = JSObject()

    southwestJS.put("lat", bounds.southwest.latitude)
    southwestJS.put("lng", bounds.southwest.longitude)
    centerJS.put("lat", bounds.center.latitude)
    centerJS.put("lng", bounds.center.longitude)
    northeastJS.put("lat", bounds.northeast.latitude)
    northeastJS.put("lng", bounds.northeast.longitude)

    data.put("southwest", southwestJS)
    data.put("center", centerJS)
    data.put("northeast", northeastJS)

    return data
}
