package com.capacitorjs.plugins.googlemaps

interface PluginAsyncInterface {
    fun onPostExecute(`object`: AsyncLoadImage.AsyncLoadImageResult?)
    fun onError(errorMsg: String?)
}

public class PluginAsync(private val onPostExecuteFunc: (AsyncLoadImage.AsyncLoadImageResult?) -> Unit,
						 private val onErrorFunc: (String?) -> Unit): PluginAsyncInterface {
	override fun onPostExecute(`object`: AsyncLoadImage.AsyncLoadImageResult?) {
		onPostExecuteFunc(`object`)
	}

	override fun onError(errorMsg: String?) {
		onErrorFunc(errorMsg)
	}

}

