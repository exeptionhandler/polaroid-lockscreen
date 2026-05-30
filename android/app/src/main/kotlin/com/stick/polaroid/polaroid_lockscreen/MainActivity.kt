package com.stick.polaroid.polaroid_lockscreen

import android.content.ComponentName
import android.content.Intent
import android.app.WallpaperManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.stick.polaroid/wallpaper_config"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "openWallpaperChooser") {
                try {
                    val intent = Intent(WallpaperManager.ACTION_CHANGE_LIVE_WALLPAPER).apply {
                        putExtra(
                            WallpaperManager.EXTRA_LIVE_WALLPAPER_COMPONENT,
                            ComponentName(context, LiveWallpaperService::class.java)
                        )
                    }
                    startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    // Fallback to standard Live Wallpaper Chooser
                    try {
                        val intent = Intent(WallpaperManager.ACTION_LIVE_WALLPAPER_CHOOSER)
                        startActivity(intent)
                        result.success(true)
                    } catch (ex: Exception) {
                        result.error("UNAVAILABLE", "No se pudo abrir el selector de fondos", ex.message)
                    }
                }
            } else {
                result.notImplemented()
            }
        }
    }
}
