package com.stick.polaroid.polaroid_lockscreen

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.service.wallpaper.WallpaperService
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.renderer.FlutterRenderer
import io.flutter.plugin.common.MethodChannel

class LiveWallpaperService : WallpaperService() {

    override fun onCreateEngine(): Engine {
        return FlutterWallpaperEngine()
    }

    inner class FlutterWallpaperEngine : Engine() {
        private var flutterEngine: FlutterEngine? = null
        private var methodChannel: MethodChannel? = null
        private val mainHandler = Handler(Looper.getMainLooper())

        override fun onCreate(surfaceHolder: SurfaceHolder?) {
            super.onCreate(surfaceHolder)

            // Flutter initialization must happen on the Main Thread
            mainHandler.post {
                val context = this@LiveWallpaperService
                val flutterLoader = FlutterInjector.instance().flutterLoader()
                if (!flutterLoader.didInit()) {
                    flutterLoader.startInitialization(context)
                }
                flutterLoader.ensureInitializationComplete(context, null)

                val engine = FlutterEngine(context)
                flutterEngine = engine

                // Connect the MethodChannel to communicate with Dart
                methodChannel = MethodChannel(engine.dartExecutor.binaryMessenger, "com.stick.polaroid/wallpaper")

                // Execute the wallpaperMain Dart entrypoint
                val entryPoint = DartExecutor.DartEntrypoint(
                    flutterLoader.findAppBundlePath(),
                    "wallpaperMain"
                )
                engine.dartExecutor.executeDartEntrypoint(entryPoint)
            }
        }

        override fun onVisibilityChanged(visible: Boolean) {
            super.onVisibilityChanged(visible)
            mainHandler.post {
                methodChannel?.invokeMethod("onVisibilityChanged", visible)
            }
        }

        override fun onSurfaceCreated(holder: SurfaceHolder) {
            super.onSurfaceCreated(holder)
            mainHandler.post {
                flutterEngine?.let { engine ->
                    engine.renderer.startRenderingToSurface(holder.surface, false)
                }
            }
        }

        override fun onSurfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
            super.onSurfaceChanged(holder, format, width, height)
            mainHandler.post {
                flutterEngine?.let { engine ->
                    engine.renderer.surfaceChanged(width, height)
                    
                    // Update the viewport metrics in the engine so it knows the size of the wallpaper
                    val metrics = FlutterRenderer.ViewportMetrics().apply {
                        this.width = width
                        this.height = height
                        this.devicePixelRatio = resources.displayMetrics.density
                    }
                    engine.renderer.setViewportMetrics(metrics)
                }
            }
        }

        override fun onSurfaceDestroyed(holder: SurfaceHolder) {
            super.onSurfaceDestroyed(holder)
            mainHandler.post {
                flutterEngine?.renderer?.stopRenderingToSurface()
            }
        }

        override fun onTouchEvent(event: MotionEvent?) {
            super.onTouchEvent(event)
            if (event?.action == MotionEvent.ACTION_DOWN) {
                mainHandler.post {
                    methodChannel?.invokeMethod("onTouch", mapOf("x" to event.x, "y" to event.y))
                }
            }
        }

        override fun onDestroy() {
            mainHandler.post {
                flutterEngine?.destroy()
                flutterEngine = null
                methodChannel = null
            }
            super.onDestroy()
        }
    }
}
