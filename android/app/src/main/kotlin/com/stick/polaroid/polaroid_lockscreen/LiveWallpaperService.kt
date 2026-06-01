package com.stick.polaroid.polaroid_lockscreen

import android.content.Context
import android.content.SharedPreferences
import android.graphics.*
import android.os.Handler
import android.os.Looper
import android.service.wallpaper.WallpaperService
import android.view.Choreographer
import android.view.MotionEvent
import android.view.SurfaceHolder
import org.json.JSONArray
import java.io.File
import kotlin.math.*
import kotlin.random.Random

class LiveWallpaperService : WallpaperService() {

    override fun onCreateEngine(): Engine {
        return NativeWallpaperEngine()
    }

    private fun writeLog(msg: String) {
        try {
            val logFile = File(applicationContext.filesDir, "wallpaper_log.txt")
            logFile.appendText("${java.util.Date()}: $msg\n")
            if (logFile.length() > 50_000) {
                val lines = logFile.readLines().takeLast(50)
                logFile.writeText(lines.joinToString("\n") + "\n")
            }
        } catch (_: Exception) {}
    }

    // ─────────────────────────────────────────────
    // Data classes
    // ─────────────────────────────────────────────
    data class Star(val x: Float, val y: Float, val phase: Float)

    class PolaroidParticle(
        var x: Float,
        var y: Float,
        var vx: Float,
        var vy: Float,
        var angle: Float,
        var vAngle: Float,
        var scale: Float = 1f,
        var bitmap: Bitmap?,
        val index: Int,
        var startX: Float = 0f,
        var startY: Float = 0f,
        var startAngle: Float = 0f
    ) {
        val radius: Float get() = 55f * scale
        val mass: Float get() = 1f
    }

    // Selection animation phases
    enum class SelectionPhase {
        FLOATING,    // Normal floating
        ZOOMING_IN,  // Zooming to center (1.2s)
        HOLDING,     // Holding at center full-screen (3s)
        ZOOMING_OUT, // Shrinking back (1.0s)
    }

    // ─────────────────────────────────────────────
    // Native Wallpaper Engine
    // ─────────────────────────────────────────────
    inner class NativeWallpaperEngine : Engine(), Choreographer.FrameCallback {

        private var surfaceWidth = 0
        private var surfaceHeight = 0
        private var visible = false
        private var holder: SurfaceHolder? = null

        private val particles = mutableListOf<PolaroidParticle>()
        private val stars = mutableListOf<Star>()
        private val rng = Random(System.nanoTime())
        private var lastFrameNanos = 0L

        // Selection animation state
        private var elapsedTime = 0.0
        private var selectionPhase = SelectionPhase.FLOATING
        private var selectedIdx = -1
        private var phaseProgress = 0.0  // 0..1 within current phase
        private var holdTimer = 0.0

        private var loveNote = "Te amo ❤️"
        private var polaroidEmoji = "❤️"

        // Pre-allocated paints
        private val bgPaint = Paint()
        private val starPaint = Paint().apply { style = Paint.Style.FILL; isAntiAlias = true }
        private val shadowPaint = Paint().apply {
            color = Color.argb(90, 0, 0, 0)
            maskFilter = BlurMaskFilter(8f, BlurMaskFilter.Blur.NORMAL)
            isAntiAlias = true
        }
        private val framePaint = Paint().apply {
            color = Color.WHITE; style = Paint.Style.FILL; isAntiAlias = true
        }
        private val imgPaint = Paint().apply { isAntiAlias = true; isFilterBitmap = true }
        private val overlayPaint = Paint()
        private val placeholderPaint = Paint().apply { isAntiAlias = true }
        private val notePaint = Paint().apply {
            color = Color.rgb(255, 75, 114)
            isAntiAlias = true
            textAlign = Paint.Align.CENTER
            typeface = Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD_ITALIC)
        }

        private var bgGradient: LinearGradient? = null
        private val choreographer = Choreographer.getInstance()

        override fun onCreate(surfaceHolder: SurfaceHolder?) {
            super.onCreate(surfaceHolder)
            setTouchEventsEnabled(true)
            writeLog("NATIVE: onCreate called")
        }

        override fun onSurfaceCreated(holder: SurfaceHolder) {
            super.onSurfaceCreated(holder)
            this.holder = holder
            writeLog("NATIVE: onSurfaceCreated")
        }

        override fun onSurfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
            super.onSurfaceChanged(holder, format, width, height)
            this.holder = holder
            surfaceWidth = width
            surfaceHeight = height
            writeLog("NATIVE: onSurfaceChanged ${width}x${height}")

            bgGradient = LinearGradient(
                0f, 0f, 0f, height.toFloat(),
                intArrayOf(
                    Color.rgb(26, 16, 64),
                    Color.rgb(42, 30, 85),
                    Color.rgb(61, 46, 110)
                ),
                floatArrayOf(0f, 0.5f, 1f),
                Shader.TileMode.CLAMP
            )

            generateStars(width, height)
            loadImagesAndInit()
        }

        override fun onVisibilityChanged(visible: Boolean) {
            super.onVisibilityChanged(visible)
            this.visible = visible
            writeLog("NATIVE: onVisibilityChanged $visible")

            if (visible) {
                lastFrameNanos = System.nanoTime()
                choreographer.postFrameCallback(this)
            } else {
                choreographer.removeFrameCallback(this)
            }
        }

        override fun onTouchEvent(event: MotionEvent?) {
            super.onTouchEvent(event)
            if (event?.action == MotionEvent.ACTION_DOWN) {
                handleTouch(event.x, event.y)
            }
        }

        override fun onSurfaceDestroyed(holder: SurfaceHolder) {
            super.onSurfaceDestroyed(holder)
            this.visible = false
            choreographer.removeFrameCallback(this)
            this.holder = null
            writeLog("NATIVE: onSurfaceDestroyed")
        }

        override fun onDestroy() {
            writeLog("NATIVE: onDestroy")
            visible = false
            choreographer.removeFrameCallback(this)
            for (p in particles) { p.bitmap?.recycle(); p.bitmap = null }
            particles.clear()
            super.onDestroy()
        }

        // ─── Choreographer callback ───
        override fun doFrame(frameTimeNanos: Long) {
            if (!visible) return

            val dt = if (lastFrameNanos == 0L) 0.016f
            else ((frameTimeNanos - lastFrameNanos) / 1_000_000_000.0).toFloat().coerceIn(0f, 0.05f)
            lastFrameNanos = frameTimeNanos

            updatePhysics(dt)
            drawFrame()

            if (visible) {
                choreographer.postFrameCallback(this)
            }
        }

        // ─── Image Loading (handles Flutter's SharedPreferences format) ───
        private fun loadImagesAndInit() {
            try {
                val prefs: SharedPreferences = applicationContext.getSharedPreferences(
                    "FlutterSharedPreferences", Context.MODE_PRIVATE
                )

                // Flutter's setStringList stores data in multiple possible formats.
                // Try all known formats to maximize compatibility.
                val paths = mutableListOf<String>()

                // Method 1: Try reading as StringSet (older flutter shared_preferences)
                try {
                    val pathsSet = prefs.getStringSet("flutter.selected_images", null)
                    if (pathsSet != null && pathsSet.isNotEmpty()) {
                        paths.addAll(pathsSet)
                        writeLog("NATIVE: loaded paths from StringSet: ${paths.size}")
                    }
                } catch (e: Exception) {
                    writeLog("NATIVE: StringSet read failed: ${e.message}")
                }

                // Method 2: Try reading as String (newer flutter shared_preferences uses JSON prefix)
                if (paths.isEmpty()) {
                    try {
                        val raw = prefs.getString("flutter.selected_images", null)
                        if (raw != null) {
                            writeLog("NATIVE: raw string value: ${raw.take(200)}")
                            // Find the first '[' character to robustly extract the JSON array
                            val bracketIndex = raw.indexOf('[')
                            val jsonStr = if (bracketIndex >= 0) {
                                raw.substring(bracketIndex)
                            } else {
                                raw
                            }
                            val jsonArray = JSONArray(jsonStr)
                            for (i in 0 until jsonArray.length()) {
                                paths.add(jsonArray.getString(i))
                            }
                            writeLog("NATIVE: loaded paths from JSON string: ${paths.size}")
                        }
                    } catch (e: Exception) {
                        writeLog("NATIVE: String/JSON read failed: ${e.message}")
                    }
                }

                // Method 3: Scan all keys for debug
                if (paths.isEmpty()) {
                    val allKeys = prefs.all.keys
                    writeLog("NATIVE: all SharedPrefs keys: ${allKeys.joinToString(", ")}")
                    for (key in allKeys) {
                        if (key.contains("image", ignoreCase = true)) {
                            val value = prefs.all[key]
                            writeLog("NATIVE: key=$key type=${value?.javaClass?.simpleName} value=${value.toString().take(200)}")
                        }
                    }
                }

                loveNote = prefs.getString("flutter.love_note", "Te amo ❤️") ?: "Te amo ❤️"
                polaroidEmoji = prefs.getString("flutter.polaroid_emoji", "❤️") ?: "❤️"
                writeLog("NATIVE: final paths count=${paths.size}, loveNote=$loveNote, emoji=$polaroidEmoji")

                val bitmaps = mutableListOf<Bitmap?>()
                for (path in paths) {
                    try {
                        val file = File(path)
                        if (file.exists()) {
                            val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                            BitmapFactory.decodeFile(path, opts)

                            val targetSize = 300
                            var sampleSize = 1
                            while (opts.outWidth / sampleSize > targetSize * 2 ||
                                opts.outHeight / sampleSize > targetSize * 2) {
                                sampleSize *= 2
                            }

                            val decodeOpts = BitmapFactory.Options().apply { inSampleSize = sampleSize }
                            val bmp = BitmapFactory.decodeFile(path, decodeOpts)
                            if (bmp != null) {
                                val sz = min(bmp.width, bmp.height)
                                val cropped = Bitmap.createBitmap(
                                    bmp, (bmp.width - sz) / 2, (bmp.height - sz) / 2, sz, sz
                                )
                                if (cropped !== bmp) bmp.recycle()
                                bitmaps.add(cropped)
                                writeLog("NATIVE: loaded image $path (${cropped.width}x${cropped.height})")
                            }
                        } else {
                            writeLog("NATIVE: file not found $path")
                        }
                    } catch (e: Exception) {
                        writeLog("NATIVE: error loading image: ${e.message}")
                    }
                }

                initParticles(bitmaps)
            } catch (e: Exception) {
                writeLog("NATIVE: loadImagesAndInit FAILED: ${e.message}")
                initParticles(emptyList())
            }
        }

        private fun initParticles(bitmaps: List<Bitmap?>) {
            particles.clear()
            elapsedTime = 0.0
            selectionPhase = SelectionPhase.FLOATING
            selectedIdx = -1
            phaseProgress = 0.0
            holdTimer = 0.0

            val count = if (bitmaps.isEmpty()) 4 else bitmaps.size
            val w = surfaceWidth.toFloat()
            val h = surfaceHeight.toFloat()

            for (i in 0 until count) {
                val bmp = if (bitmaps.isEmpty()) null else bitmaps[i]
                val x = 80f + rng.nextFloat() * (w - 160f)
                val y = 100f + rng.nextFloat() * (h - 200f)
                val randAngle = rng.nextFloat() * 2f * PI.toFloat()
                val speed = 40f + rng.nextFloat() * 40f

                particles.add(PolaroidParticle(
                    x = x, y = y,
                    vx = cos(randAngle) * speed,
                    vy = sin(randAngle) * speed,
                    angle = (rng.nextFloat() - 0.5f) * 0.4f,
                    vAngle = (rng.nextFloat() - 0.5f) * 0.3f,
                    bitmap = bmp,
                    index = i
                ))
            }

            writeLog("NATIVE: initParticles ${particles.size} particles, screen=${surfaceWidth}x${surfaceHeight}")

            if (visible) {
                lastFrameNanos = System.nanoTime()
                choreographer.postFrameCallback(this)
            }
        }

        private fun generateStars(width: Int, height: Int) {
            stars.clear()
            for (i in 0 until 50) {
                stars.add(Star(
                    x = rng.nextFloat() * width,
                    y = rng.nextFloat() * height,
                    phase = rng.nextFloat() * (2f * PI.toFloat())
                ))
            }
        }

        // ─── Physics Update with improved selection animation ───
        private fun updatePhysics(dt: Float) {
            if (particles.isEmpty()) return
            val w = surfaceWidth.toFloat()
            val h = surfaceHeight.toFloat()
            if (w <= 0 || h <= 0) return

            when (selectionPhase) {
                SelectionPhase.FLOATING -> {
                    elapsedTime += dt
                    if (elapsedTime >= 4.0) {
                        // Start selection: pick a random polaroid
                        selectionPhase = SelectionPhase.ZOOMING_IN
                        selectedIdx = rng.nextInt(particles.size)
                        phaseProgress = 0.0
                        val sel = particles[selectedIdx]
                        sel.startX = sel.x
                        sel.startY = sel.y
                        sel.startAngle = sel.angle
                    }
                }

                SelectionPhase.ZOOMING_IN -> {
                    phaseProgress += dt / 1.2  // 1.2 seconds to zoom in
                    if (phaseProgress >= 1.0) {
                        phaseProgress = 1.0
                        selectionPhase = SelectionPhase.HOLDING
                        holdTimer = 0.0
                    }
                }

                SelectionPhase.HOLDING -> {
                    holdTimer += dt
                    if (holdTimer >= 3.5) {
                        // Start shrinking back
                        selectionPhase = SelectionPhase.ZOOMING_OUT
                        phaseProgress = 0.0
                        // Save current (centered) position as start for zoom-out
                        val sel = particles[selectedIdx]
                        sel.startX = sel.x
                        sel.startY = sel.y
                        sel.startAngle = sel.angle
                    }
                }

                SelectionPhase.ZOOMING_OUT -> {
                    phaseProgress += dt / 1.0  // 1 second to shrink back
                    if (phaseProgress >= 1.0) {
                        phaseProgress = 1.0
                        // Reset: go back to floating, give it new velocity
                        val sel = particles[selectedIdx]
                        sel.scale = 1f
                        val randAngle = rng.nextFloat() * 2f * PI.toFloat()
                        val speed = 40f + rng.nextFloat() * 40f
                        sel.vx = cos(randAngle) * speed
                        sel.vy = sin(randAngle) * speed
                        sel.vAngle = (rng.nextFloat() - 0.5f) * 0.3f

                        selectionPhase = SelectionPhase.FLOATING
                        selectedIdx = -1
                        elapsedTime = 0.0
                        phaseProgress = 0.0
                    }
                }
            }

            // Position updates
            for (i in particles.indices) {
                val p = particles[i]
                val isSelected = i == selectedIdx && selectionPhase != SelectionPhase.FLOATING

                if (isSelected) {
                    when (selectionPhase) {
                        SelectionPhase.ZOOMING_IN -> {
                            val t = easeInOut(phaseProgress.toFloat())
                            val targetX = w / 2f
                            val targetY = h / 2f
                            // Scale to fill ~80% of screen width
                            val targetScale = (w * 0.8f) / 110f

                            p.x = lerp(p.startX, targetX, t)
                            p.y = lerp(p.startY, targetY, t)
                            p.angle = lerp(p.startAngle, 0f, t)
                            p.scale = lerp(1f, targetScale, t)
                        }

                        SelectionPhase.HOLDING -> {
                            // Stay centered, gentle breathing effect
                            p.x = w / 2f
                            p.y = h / 2f
                            p.angle = 0f
                            val targetScale = (w * 0.8f) / 110f
                            val breathe = sin(holdTimer.toFloat() * 2f) * 0.03f
                            p.scale = targetScale + breathe
                        }

                        SelectionPhase.ZOOMING_OUT -> {
                            val t = easeInOut(phaseProgress.toFloat())
                            val targetScale = (w * 0.8f) / 110f
                            // Pick a random floating position to land
                            val landX = 80f + (p.index.toFloat() / particles.size) * (w - 160f)
                            val landY = 100f + (p.index.toFloat() / particles.size) * (h - 200f)
                            val landAngle = (rng.nextFloat() - 0.5f) * 0.3f

                            p.x = lerp(p.startX, landX, t)
                            p.y = lerp(p.startY, landY, t)
                            p.angle = lerp(0f, landAngle, t)
                            p.scale = lerp(targetScale, 1f, t)
                        }

                        else -> {}
                    }
                } else {
                    p.x += p.vx * dt
                    p.y += p.vy * dt
                    p.angle += p.vAngle * dt

                    val speed = sqrt(p.vx * p.vx + p.vy * p.vy)
                    if (speed > 150f) {
                        p.vx = (p.vx / speed) * 150f
                        p.vy = (p.vy / speed) * 150f
                    }

                    p.vAngle *= 0.98f

                    val rad = p.radius
                    if (p.x - rad < 0) { p.x = rad; p.vx = abs(p.vx) * 0.95f }
                    else if (p.x + rad > w) { p.x = w - rad; p.vx = -abs(p.vx) * 0.95f }

                    if (p.y - rad < 0) { p.y = rad; p.vy = abs(p.vy) * 0.95f }
                    else if (p.y + rad > h) { p.y = h - rad; p.vy = -abs(p.vy) * 0.95f }
                }
            }

            // Elastic collisions (skip selected)
            for (i in particles.indices) {
                if (i == selectedIdx && selectionPhase != SelectionPhase.FLOATING) continue
                for (j in (i + 1) until particles.size) {
                    if (j == selectedIdx && selectionPhase != SelectionPhase.FLOATING) continue
                    val p1 = particles[i]
                    val p2 = particles[j]

                    val dx = p2.x - p1.x
                    val dy = p2.y - p1.y
                    val dist = sqrt(dx * dx + dy * dy)
                    val minDist = p1.radius + p2.radius

                    if (dist < minDist && dist > 0) {
                        val overlap = minDist - dist
                        val rx = (dx / dist) * overlap * 0.5f
                        val ry = (dy / dist) * overlap * 0.5f

                        p1.x -= rx; p1.y -= ry
                        p2.x += rx; p2.y += ry

                        val nx = dx / dist
                        val ny = dy / dist
                        val rvx = p2.vx - p1.vx
                        val rvy = p2.vy - p1.vy
                        val velNormal = rvx * nx + rvy * ny

                        if (velNormal < 0) {
                            val impulse = -(1f + 0.9f) * velNormal / (1f / p1.mass + 1f / p2.mass)
                            p1.vx -= (impulse / p1.mass) * nx
                            p1.vy -= (impulse / p1.mass) * ny
                            p2.vx += (impulse / p2.mass) * nx
                            p2.vy += (impulse / p2.mass) * ny

                            p1.vAngle += (rng.nextFloat() - 0.5f) * 1.5f
                            p2.vAngle += (rng.nextFloat() - 0.5f) * 1.5f
                        }
                    }
                }
            }
        }

        private fun handleTouch(tx: Float, ty: Float) {
            if (selectionPhase != SelectionPhase.FLOATING) {
                // Reset to floating on touch
                if (selectedIdx in particles.indices) {
                    particles[selectedIdx].scale = 1f
                }
                selectionPhase = SelectionPhase.FLOATING
                selectedIdx = -1
                phaseProgress = 0.0
                elapsedTime = 0.0
                return
            }

            for (p in particles) {
                val dx = p.x - tx
                val dy = p.y - ty
                val dist = sqrt(dx * dx + dy * dy)
                if (dist < 200f) {
                    val force = (200f - dist) / 200f
                    val pushAngle = if (dist == 0f) rng.nextFloat() * 2f * PI.toFloat() else atan2(dy, dx)
                    p.vx += cos(pushAngle) * force * 150f
                    p.vy += sin(pushAngle) * force * 150f
                    p.vAngle += (if (p.x > tx) 1f else -1f) * force * 1.5f
                }
            }
        }

        // ─── Drawing ───
        private fun drawFrame() {
            val h = holder ?: return
            var canvas: Canvas? = null
            try {
                canvas = h.lockCanvas()
                if (canvas != null) drawScene(canvas)
            } catch (e: Exception) {
                writeLog("NATIVE: drawFrame error: ${e.message}")
            } finally {
                if (canvas != null) {
                    try { h.unlockCanvasAndPost(canvas) } catch (_: Exception) {}
                }
            }
        }

        private fun drawScene(canvas: Canvas) {
            val w = surfaceWidth.toFloat()
            val h = surfaceHeight.toFloat()

            // 1. Background gradient
            bgGradient?.let {
                bgPaint.shader = it
                canvas.drawRect(0f, 0f, w, h, bgPaint)
            } ?: run {
                canvas.drawColor(Color.rgb(26, 16, 64))
            }

            // 2. Starfield
            val timeS = (System.currentTimeMillis() % 8000L) / 8000f * 2f * PI.toFloat()
            for (star in stars) {
                val pulse = sin(timeS + star.phase)
                val opacity = (0.15f + abs(pulse) * 0.5f).coerceIn(0f, 1f)
                val radius = 1f + abs(pulse) * 2f
                starPaint.color = Color.argb((opacity * 255).toInt(), 255, 255, 255)
                canvas.drawCircle(star.x, star.y, radius, starPaint)
            }

            // 3. Draw non-selected particles
            for (i in particles.indices) {
                if (i == selectedIdx && selectionPhase != SelectionPhase.FLOATING) continue
                drawPolaroid(canvas, particles[i])
            }

            // 4. Draw overlay + selected particle on top
            if (selectionPhase != SelectionPhase.FLOATING && selectedIdx in particles.indices) {
                val overlayAlpha = when (selectionPhase) {
                    SelectionPhase.ZOOMING_IN -> (phaseProgress * 0.65 * 255).toInt()
                    SelectionPhase.HOLDING -> (0.65 * 255).toInt()
                    SelectionPhase.ZOOMING_OUT -> ((1.0 - phaseProgress) * 0.65 * 255).toInt()
                    else -> 0
                }.coerceIn(0, 255)

                overlayPaint.color = Color.argb(overlayAlpha, 0, 0, 0)
                canvas.drawRect(0f, 0f, w, h, overlayPaint)
                drawPolaroid(canvas, particles[selectedIdx])
            }
        }

        private fun drawPolaroid(canvas: Canvas, p: PolaroidParticle) {
            canvas.save()
            canvas.translate(p.x, p.y)
            canvas.rotate(Math.toDegrees(p.angle.toDouble()).toFloat())
            canvas.scale(p.scale, p.scale)

            val pw = 110f
            val ph = 132f
            val left = -pw / 2f
            val top = -ph / 2f

            val rect = RectF(left, top, left + pw, top + ph)
            val cornerRadius = 4f

            // 1. Drop shadow
            canvas.drawRoundRect(
                RectF(rect.left + 3f, rect.top + 5f, rect.right + 3f, rect.bottom + 5f),
                cornerRadius, cornerRadius, shadowPaint
            )

            // 2. White frame
            canvas.drawRoundRect(rect, cornerRadius, cornerRadius, framePaint)

            // 3. Image area
            val imgW = 94f
            val imgH = 94f
            val imgLeft = -imgW / 2f
            val imgTop = top + 8f
            val imgRect = RectF(imgLeft, imgTop, imgLeft + imgW, imgTop + imgH)
            val imgCorner = 2f

            if (p.bitmap != null) {
                canvas.save()
                val clipPath = Path()
                clipPath.addRoundRect(imgRect, imgCorner, imgCorner, Path.Direction.CW)
                canvas.clipPath(clipPath)

                val bmp = p.bitmap!!
                val srcRect = Rect(0, 0, bmp.width, bmp.height)
                canvas.drawBitmap(bmp, srcRect, imgRect, imgPaint)
                canvas.restore()
            } else {
                placeholderPaint.shader = LinearGradient(
                    imgRect.left, imgRect.top, imgRect.right, imgRect.bottom,
                    Color.rgb(255, 181, 197), Color.rgb(199, 162, 229),
                    Shader.TileMode.CLAMP
                )
                canvas.drawRoundRect(imgRect, imgCorner, imgCorner, placeholderPaint)
                if (polaroidEmoji.isNotEmpty()) {
                    notePaint.textSize = 24f
                    canvas.drawText(polaroidEmoji, imgRect.centerX(), imgRect.centerY() + 8f, notePaint)
                }
            }

            // 4. Bottom note
            val isZoomed = p.index == selectedIdx &&
                    (selectionPhase == SelectionPhase.HOLDING || selectionPhase == SelectionPhase.ZOOMING_IN)
            if (isZoomed && loveNote.isNotEmpty()) {
                val cy = ph / 2f - 20f
                notePaint.textSize = 7f
                canvas.drawText(loveNote, 0f, cy, notePaint)
            } else {
                val cy = ph / 2f - 13f
                if (polaroidEmoji.isNotEmpty()) {
                    notePaint.textSize = 10f
                    canvas.drawText(polaroidEmoji, 0f, cy + 3f, notePaint)
                }
            }

            canvas.restore()
        }

        private fun lerp(a: Float, b: Float, t: Float): Float = a + (b - a) * t

        private fun easeInOut(t: Float): Float {
            return if (t < 0.5f) 2f * t * t
            else 1f - (-2f * t + 2f).pow(2) / 2f
        }
    }
}
