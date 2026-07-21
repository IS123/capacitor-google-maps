package com.capacitorjs.plugins.googlemaps;

import android.graphics.Bitmap;
import android.os.AsyncTask;

import com.getcapacitor.Bridge;
import com.google.android.gms.maps.model.BitmapDescriptor;
import com.google.android.gms.maps.model.BitmapDescriptorFactory;
import com.google.android.gms.maps.model.GroundOverlay;
import com.google.android.gms.maps.model.GroundOverlayOptions;
import com.google.android.gms.maps.model.LatLngBounds;

import java.util.HashMap;

public class CapacitorGoogleMapsGroundOverlay {
	private Bridge bridge;

	public CapacitorGoogleMapsGroundOverlay(Bridge bridge) {
		this.bridge = bridge;
	}
	private HashMap<Integer, AsyncTask> imageLoadingTasks = new HashMap<Integer, AsyncTask>();

	public void setImage_(final String imgUrl, final PluginAsyncInterface callback) {
		if (imgUrl == null) {
			callback.onPostExecute(null);
			return;
		}

		final AsyncLoadImage.AsyncLoadImageOptions imageOptions = new AsyncLoadImage.AsyncLoadImageOptions();
		imageOptions.height = -1;
		imageOptions.width = -1;
		imageOptions.noCaching = true;
		imageOptions.url = imgUrl;
		final int taskId = imageOptions.hashCode();

		final AsyncLoadImageInterface onComplete = new AsyncLoadImageInterface() {

			@Override
			public void onPostExecute(AsyncLoadImage.AsyncLoadImageResult result) {
				if (result == null || result.image == null) {
					callback.onError("Can not read image from " + imgUrl);
					imageLoadingTasks.remove(taskId).cancel(true);
					return;
				}

				callback.onPostExecute(result);

				imageLoadingTasks.remove(taskId).cancel(true);
			}
		};
		bridge.getActivity().runOnUiThread(new Runnable() {
			@Override
			public void run() {
				AsyncLoadImage task = new AsyncLoadImage(bridge.getWebView(), imageOptions, onComplete);
				//cordova.getActivity().runOnUiThread(new Runnable() {
				//  @Override
				//  public void run() {
				//    task.execute();
				//  }
				//});
				task.execute();
				imageLoadingTasks.put(taskId, task);
			}
		});
	}
}
