package com.stick.polaroid.polaroid_lockscreen

import android.app.WallpaperManager
import android.content.ComponentName
import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.stick.polaroid/wallpaper_config"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openWallpaperChooser" -> {
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
                        try {
                            val intent = Intent(WallpaperManager.ACTION_LIVE_WALLPAPER_CHOOSER)
                            startActivity(intent)
                            result.success(true)
                        } catch (ex: Exception) {
                            result.error("UNAVAILABLE", "No se pudo abrir el selector de fondos", ex.message)
                        }
                    }
                }

                "applyToLockScreen" -> {
                    // For Android 7+ (API 24+), we can set wallpaper specifically for lock screen
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                            // First, open the live wallpaper chooser so the system registers our service
                            val intent = Intent(WallpaperManager.ACTION_CHANGE_LIVE_WALLPAPER).apply {
                                putExtra(
                                    WallpaperManager.EXTRA_LIVE_WALLPAPER_COMPONENT,
                                    ComponentName(context, LiveWallpaperService::class.java)
                                )
                            }
                            startActivity(intent)
                            result.success(true)
                        } else {
                            result.error("UNSUPPORTED", "Lock screen wallpaper requires Android 7+", null)
                        }
                    } catch (e: Exception) {
                        result.error("ERROR", "Error applying lock screen wallpaper: ${e.message}", null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }
}
