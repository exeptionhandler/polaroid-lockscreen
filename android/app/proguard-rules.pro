# Proguard rules for polaroid-lockscreen

# Flutter Engine & Wrapper classes
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.provider.** { *; }
-keep class io.flutter.plugin.editing.** { *; }

# Keep platform channels and basic engine components
-keep class io.flutter.plugin.common.** { *; }
-keep class io.flutter.embedding.engine.renderer.** { *; }
-keep class io.flutter.embedding.engine.dart.** { *; }

# Keep native application entrypoints and wallpaper service
-keep class com.stick.polaroid.polaroid_lockscreen.LiveWallpaperService { *; }
-keep class com.stick.polaroid.polaroid_lockscreen.LiveWallpaperService$FlutterWallpaperEngine { *; }
-keep class com.stick.polaroid.polaroid_lockscreen.MainActivity { *; }

# Keep GeneratedPluginRegistrant (accessed via reflection in LiveWallpaperService)
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }

# Suppress warnings that might block the build
-dontwarn io.flutter.embedding.android.**
-dontwarn com.google.android.play.core.**
