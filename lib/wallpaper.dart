import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Logging helper - imported from main.dart won't work, so we redefine
const _wpLogChannel = MethodChannel('com.stick.polaroid/wallpaper');
void _wpLog(String msg) {
  try { _wpLogChannel.invokeMethod('writeLog', msg); } catch (_) {}
}

class PolaroidParticle {
  double x;
  double y;
  double vx;
  double vy;
  double angle;
  double vAngle;
  double scale;
  final ui.Image? image;
  final int index;

  // For selection interpolation
  double startX = 0;
  double startY = 0;
  double startAngle = 0;

  PolaroidParticle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.angle,
    required this.vAngle,
    this.scale = 1.0,
    required this.image,
    required this.index,
  });

  double get radius => 55.0 * scale;
  double get mass => 1.0;
}

class PolaroidWallpaperPage extends StatefulWidget {
  const PolaroidWallpaperPage({Key? key}) : super(key: key);

  @override
  _PolaroidWallpaperPageState createState() => _PolaroidWallpaperPageState();
}

class _PolaroidWallpaperPageState extends State<PolaroidWallpaperPage> with TickerProviderStateMixin, WidgetsBindingObserver {
  static const _channel = MethodChannel('com.stick.polaroid/wallpaper');
  
  List<ui.Image> _loadedImages = [];
  bool _isVisible = true;
  String _loveNote = 'Te amo ❤️';
  String _debugInfo = 'Iniciando...';

  // Physics & Animation
  final List<PolaroidParticle> _particles = [];
  late AnimationController _controller;
  DateTime? _lastTick;
  
  // Selection timer & state
  double _elapsedTime = 0.0;
  bool _isSelecting = false;
  int _selectedIdx = -1;
  double _selectionProgress = 0.0;
  
  Size _screenSize = Size.zero;
  final math.Random _random = math.Random();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _wpLog('PolaroidWallpaperPage: initState called');
    
    // Animation controller for physics tick
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 16),
    )..addListener(_tick);

    _setupMethodChannel();
    
    // Load images in background with timeout - don't block rendering
    _loadImagesWithTimeout();
    _wpLog('PolaroidWallpaperPage: initState complete');
  }

  void _setupMethodChannel() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onVisibilityChanged':
          final visible = call.arguments as bool;
          setState(() {
            _isVisible = visible;
          });
          if (visible) {
            _resumePhysics();
          } else {
            _pausePhysics();
          }
          break;
        case 'onTouch':
          final args = call.arguments as Map;
          final x = args['x'] as double;
          final y = args['y'] as double;
          _handleTouch(x, y);
          break;
      }
    });
  }

  /// Load images with a 3-second timeout. If SharedPreferences hangs,
  /// we still show placeholder particles instead of a black screen.
  Future<void> _loadImagesWithTimeout() async {
    _wpLog('_loadImages: starting');
    try {
      // Timeout to prevent SharedPreferences from hanging forever
      _wpLog('_loadImages: getting SharedPreferences...');
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 3), onTimeout: () {
        throw TimeoutException('SharedPreferences timed out');
      });
      _wpLog('_loadImages: SharedPreferences obtained');
      
      final paths = prefs.getStringList('selected_images') ?? [];
      final loveNote = prefs.getString('love_note') ?? 'Te amo ❤️';
      
      _wpLog('_loadImages: found ${paths.length} image paths');
      
      final List<ui.Image> images = [];
      for (final path in paths) {
        try {
          if (await File(path).exists()) {
            final image = await _loadImage(path);
            images.add(image);
            _wpLog('_loadImages: loaded image from $path');
          } else {
            _wpLog('_loadImages: file NOT FOUND $path');
          }
        } catch (e) {
          _wpLog('_loadImages: error loading image: $e');
        }
      }

      if (mounted) {
        setState(() {
          _loadedImages = images;
          _loveNote = loveNote;
        });
        _wpLog('_loadImages: SUCCESS - ${images.length} images loaded');
        _initializeParticles();
      }
    } catch (e) {
      _wpLog('_loadImages: FAILED - $e');
    }
  }

  void _updateDebug(String msg) {
    if (mounted) {
      setState(() {
        _debugInfo = msg;
      });
    }
  }

  Future<ui.Image> _loadImage(String path) async {
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    _wpLog('didChangeMetrics: updating size');
    _updateScreenSizeFromDispatcher();
  }

  void _updateScreenSizeFromDispatcher() {
    try {
      final view = ui.PlatformDispatcher.instance.views.first;
      final physicalSize = view.physicalSize;
      final dpr = view.devicePixelRatio;
      if (physicalSize.width > 0 && physicalSize.height > 0 && dpr > 0) {
        final logicalSize = Size(physicalSize.width / dpr, physicalSize.height / dpr);
        if (_screenSize != logicalSize) {
          _wpLog('_updateScreenSizeFromDispatcher: size changed to $logicalSize');
          setState(() {
            _screenSize = logicalSize;
          });
          _initializeParticles();
        }
      }
    } catch (e) {
      _wpLog('_updateScreenSizeFromDispatcher: error $e');
    }
  }

  void _initializeParticles() {
    _wpLog('_initParticles: screenSize=$_screenSize, images=${_loadedImages.length}');
    if (_screenSize == Size.zero) {
      _wpLog('_initParticles: SKIPPED - screenSize is zero');
      return;
    }
    
    _particles.clear();
    _elapsedTime = 0.0;
    _isSelecting = false;
    _selectedIdx = -1;
    _selectionProgress = 0.0;

    // Use loaded images or generate 4 default placeholders
    final count = _loadedImages.isEmpty ? 4 : _loadedImages.length;
    
    for (int i = 0; i < count; i++) {
      final img = _loadedImages.isEmpty ? null : _loadedImages[i];
      
      // Random coordinates that aren't too close to borders
      final x = 80.0 + _random.nextDouble() * (_screenSize.width - 160.0);
      final y = 100.0 + _random.nextDouble() * (_screenSize.height - 200.0);
      
      // Zero gravity velocity vectors (smooth and gentle floating)
      final angle = _random.nextDouble() * 2 * math.pi;
      final speed = 40.0 + _random.nextDouble() * 40.0;
      final vx = math.cos(angle) * speed;
      final vy = math.sin(angle) * speed;

      _particles.add(
        PolaroidParticle(
          x: x,
          y: y,
          vx: vx,
          vy: vy,
          angle: (_random.nextDouble() - 0.5) * 0.4,
          vAngle: (_random.nextDouble() - 0.5) * 0.3,
          image: img,
          index: i,
        ),
      );
    }

    _lastTick = DateTime.now();
    if (_isVisible) {
      _controller.repeat();
    }
  }

  void _resumePhysics() {
    _initializeParticles();
  }

  void _pausePhysics() {
    _controller.stop();
  }

  void _handleTouch(double tx, double ty) {
    if (_isSelecting) return;
    
    for (final p in _particles) {
      final dx = p.x - tx;
      final dy = p.y - ty;
      final dist = math.sqrt(dx * dx + dy * dy);
      if (dist < 200.0) {
        final force = (200.0 - dist) / 200.0;
        final pushAngle = dist == 0 ? _random.nextDouble() * 2 * math.pi : math.atan2(dy, dx);
        p.vx += math.cos(pushAngle) * force * 150.0;
        p.vy += math.sin(pushAngle) * force * 150.0;
        p.vAngle += (p.x > tx ? 1 : -1) * force * 1.5;
      }
    }
  }

  void _tick() {
    final now = DateTime.now();
    if (_lastTick == null) {
      _lastTick = now;
      return;
    }
    
    final dt = now.difference(_lastTick!).inMicroseconds / 1000000.0;
    _lastTick = now;
    
    _updatePhysics(dt);
  }

  void _updatePhysics(double dt) {
    if (_particles.isEmpty || _screenSize == Size.zero) return;

    if (!_isSelecting) {
      _elapsedTime += dt;
      if (_elapsedTime >= 2.5) {
        _isSelecting = true;
        _selectedIdx = _random.nextInt(_particles.length);
        
        final selected = _particles[_selectedIdx];
        selected.startX = selected.x;
        selected.startY = selected.y;
        selected.startAngle = selected.angle;
      }
    }

    if (_isSelecting && _selectedIdx != -1) {
      _selectionProgress += dt * 1.2;
      if (_selectionProgress >= 1.0) {
        _selectionProgress = 1.0;
        _controller.stop();
      }
    }

    // 1. Position Updates
    for (int i = 0; i < _particles.length; i++) {
      final p = _particles[i];
      
      if (i == _selectedIdx && _isSelecting) {
        final t = Curves.easeInOut.transform(_selectionProgress);
        final targetX = _screenSize.width / 2;
        final targetY = _screenSize.height / 2;
        
        p.x = ui.lerpDouble(p.startX, targetX, t)!;
        p.y = ui.lerpDouble(p.startY, targetY, t)!;
        p.angle = ui.lerpDouble(p.startAngle, 0.0, t)!;
        p.scale = ui.lerpDouble(1.0, 2.3, t)!;
      } else {
        p.x += p.vx * dt;
        p.y += p.vy * dt;
        p.angle += p.vAngle * dt;

        final speed = math.sqrt(p.vx * p.vx + p.vy * p.vy);
        if (speed > 150.0) {
          p.vx = (p.vx / speed) * 150.0;
          p.vy = (p.vy / speed) * 150.0;
        }
        
        p.vAngle *= 0.98;

        // 2. Edge Bounces
        final rad = p.radius;
        if (p.x - rad < 0) {
          p.x = rad;
          p.vx = p.vx.abs() * 0.95;
        } else if (p.x + rad > _screenSize.width) {
          p.x = _screenSize.width - rad;
          p.vx = -p.vx.abs() * 0.95;
        }

        if (p.y - rad < 0) {
          p.y = rad;
          p.vy = p.vy.abs() * 0.95;
        } else if (p.y + rad > _screenSize.height) {
          p.y = _screenSize.height - rad;
          p.vy = -p.vy.abs() * 0.95;
        }
      }
    }

    // 3. Elastic Collisions
    for (int i = 0; i < _particles.length; i++) {
      if (i == _selectedIdx && _isSelecting) continue;
      for (int j = i + 1; j < _particles.length; j++) {
        if (j == _selectedIdx && _isSelecting) continue;
        
        final p1 = _particles[i];
        final p2 = _particles[j];
        
        final dx = p2.x - p1.x;
        final dy = p2.y - p1.y;
        final dist = math.sqrt(dx * dx + dy * dy);
        final minDist = p1.radius + p2.radius;
        
        if (dist < minDist && dist > 0) {
          final overlap = minDist - dist;
          final resolveX = (dx / dist) * overlap * 0.5;
          final resolveY = (dy / dist) * overlap * 0.5;
          
          p1.x -= resolveX;
          p1.y -= resolveY;
          p2.x += resolveX;
          p2.y += resolveY;

          final nx = dx / dist;
          final ny = dy / dist;
          
          final rvx = p2.vx - p1.vx;
          final rvy = p2.vy - p1.vy;
          
          final velAlongNormal = rvx * nx + rvy * ny;
          
          if (velAlongNormal < 0) {
            final impulse = -(1.0 + 0.9) * velAlongNormal / (1 / p1.mass + 1 / p2.mass);
            
            p1.vx -= (impulse / p1.mass) * nx;
            p1.vy -= (impulse / p1.mass) * ny;
            
            p2.vx += (impulse / p2.mass) * nx;
            p2.vy += (impulse / p2.mass) * ny;
            
            p1.vAngle += (_random.nextDouble() - 0.5) * 1.5;
            p2.vAngle += (_random.nextDouble() - 0.5) * 1.5;
          }
        }
      }
    }

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    _wpLog('build: called, particles=${_particles.length}, screenSize=$_screenSize');
    
    // Try to init size from dispatcher if zero
    if (_screenSize == Size.zero) {
      _updateScreenSizeFromDispatcher();
    }

    if (_screenSize == Size.zero) {
      _wpLog('build: INVALID constraints - showing fallback');
      return Container(
        color: const Color(0xFF1A1040),
        child: const Center(
          child: Text('Cargando...', style: TextStyle(color: Colors.white, fontSize: 16)),
        ),
      );
    }

    _wpLog('build: screenSize=$_screenSize');

    return Material(
      color: const Color(0xFF1A1040),
      child: Container(
        width: _screenSize.width,
        height: _screenSize.height,
        decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xFF1A1040), // Visible dark purple (not black)
                Color(0xFF2A1E55), // Medium dark purple
                Color(0xFF3D2E6E), // Lighter purple at bottom
              ],
            ),
          ),
          child: Stack(
            children: [
              // Aesthetic starfield/sparkles background
              Positioned.fill(
                child: StarFieldWidget(screenSize: _screenSize),
              ),
              // Physics-based Polaroid rendering
              if (_particles.isNotEmpty)
                Positioned.fill(
                  child: CustomPaint(
                    painter: PolaroidPhysicsPainter(
                      particles: _particles,
                      selectedIdx: _selectedIdx,
                      isSelecting: _isSelecting,
                      selectionProgress: _selectionProgress,
                      loveNote: _loveNote,
                    ),
                  ),
                ),
            ],
          ),
        ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }
}

class PolaroidPhysicsPainter extends CustomPainter {
  final List<PolaroidParticle> particles;
  final int selectedIdx;
  final bool isSelecting;
  final double selectionProgress;
  final String loveNote;

  PolaroidPhysicsPainter({
    required this.particles,
    required this.selectedIdx,
    required this.isSelecting,
    required this.selectionProgress,
    required this.loveNote,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Paint all regular particles first
    for (int i = 0; i < particles.length; i++) {
      if (i == selectedIdx && isSelecting) continue;
      _drawPolaroid(canvas, particles[i]);
    }

    // 2. Paint selected particle on top
    if (selectedIdx != -1 && selectedIdx < particles.length) {
      if (isSelecting) {
        final overlayPaint = Paint()
          ..color = Colors.black.withOpacity(selectionProgress * 0.55);
        canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), overlayPaint);
      }
      _drawPolaroid(canvas, particles[selectedIdx]);
    }
  }

  void _drawPolaroid(Canvas canvas, PolaroidParticle p) {
    canvas.save();
    
    canvas.translate(p.x, p.y);
    canvas.rotate(p.angle);
    canvas.scale(p.scale);

    final w = 110.0;
    final h = 132.0;
    final rect = Rect.fromLTWH(-w / 2, -h / 2, w, h);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(4.0));

    // 1. Drop shadow
    final shadowPaint = Paint()
      ..color = Colors.black.withOpacity(0.35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5.0);
    canvas.drawRRect(rrect.shift(const Offset(2.0, 4.0)), shadowPaint);

    // 2. White Polaroid frame
    final framePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawRRect(rrect, framePaint);

    // 3. Picture area
    final imgW = 94.0;
    final imgH = 94.0;
    final imgRect = Rect.fromLTWH(-imgW / 2, -h / 2 + 8.0, imgW, imgH);
    final imgRRect = RRect.fromRectAndRadius(imgRect, const Radius.circular(2.0));

    if (p.image != null) {
      canvas.save();
      canvas.clipRRect(imgRRect);
      
      final srcW = p.image!.width.toDouble();
      final srcH = p.image!.height.toDouble();
      final minDim = math.min(srcW, srcH);
      
      final srcRect = Rect.fromLTWH(
        (srcW - minDim) / 2,
        (srcH - minDim) / 2,
        minDim,
        minDim,
      );
      
      canvas.drawImageRect(p.image!, srcRect, imgRect, Paint()..isAntiAlias = true);
      canvas.restore();
    } else {
      // Romantic placeholder gradient with heart
      final gradientPaint = Paint()
        ..shader = ui.Gradient.linear(
          imgRect.topLeft,
          imgRect.bottomRight,
          [const Color(0xFFFFB5C5), const Color(0xFFC7A2E5)],
        );
      canvas.drawRRect(imgRRect, gradientPaint);

      final heartPaint = Paint()
        ..color = const Color(0xFFFF4B72)
        ..style = PaintingStyle.fill
        ..isAntiAlias = true;

      final path = Path();
      final cx = imgRect.center.dx;
      final cy = imgRect.center.dy - 3;
      final size = 16.0;

      path.moveTo(cx, cy + size / 4);
      path.cubicTo(cx - size / 2, cy - size / 2, cx - size, cy + size / 3, cx, cy + size);
      path.cubicTo(cx + size, cy + size / 3, cx + size / 2, cy - size / 2, cx, cy + size / 4);
      canvas.drawPath(path, heartPaint);
    }

    // 4. Note at bottom
    _drawPolaroidNote(canvas, w, h, p.index, p.index == selectedIdx && isSelecting);

    canvas.restore();
  }

  void _drawPolaroidNote(Canvas canvas, double w, double h, int index, bool isZoomed) {
    if (isZoomed && loveNote.isNotEmpty) {
      final textPainter = TextPainter(
        text: TextSpan(
          text: loveNote,
          style: const TextStyle(
            color: Color(0xFFFF4B72),
            fontSize: 6.0,
            fontWeight: FontWeight.w600,
            fontFamily: 'sans-serif',
            fontStyle: FontStyle.italic,
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout(maxWidth: w - 16.0);
      
      final cx = 0.0;
      final cy = h / 2 - 20.0;
      textPainter.paint(canvas, Offset(cx - textPainter.width / 2, cy));
    } else {
      final heartPaint = Paint()
        ..color = const Color(0xFFFF6B8B).withOpacity(0.8)
        ..style = PaintingStyle.fill;

      final path = Path();
      final cx = 0.0;
      final cy = h / 2 - 13.0;
      final size = 7.0;

      path.moveTo(cx, cy + size / 4);
      path.cubicTo(cx - size / 2, cy - size / 2, cx - size, cy + size / 3, cx, cy + size);
      path.cubicTo(cx + size, cy + size / 3, cx + size / 2, cy - size / 2, cx, cy + size / 4);
      canvas.drawPath(path, heartPaint);
    }
  }

  @override
  bool shouldRepaint(covariant PolaroidPhysicsPainter oldDelegate) => true;
}

/// Sparkly stars background - uses explicit size instead of MediaQuery
class StarFieldWidget extends StatefulWidget {
  final Size screenSize;
  const StarFieldWidget({Key? key, required this.screenSize}) : super(key: key);

  @override
  _StarFieldWidgetState createState() => _StarFieldWidgetState();
}

class _StarFieldWidgetState extends State<StarFieldWidget> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  final List<ui.Offset> _stars = [];
  final math.Random _random = math.Random();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
    _generateStars();
  }

  void _generateStars() {
    _stars.clear();
    final size = widget.screenSize;
    if (size.width > 0 && size.height > 0) {
      for (int i = 0; i < 40; i++) {
        _stars.add(ui.Offset(
          _random.nextDouble() * size.width,
          _random.nextDouble() * size.height,
        ));
      }
    }
  }

  @override
  void didUpdateWidget(StarFieldWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.screenSize != widget.screenSize && _stars.isEmpty) {
      _generateStars();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          painter: StarFieldPainter(stars: _stars, progress: _controller.value),
        );
      },
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class StarFieldPainter extends CustomPainter {
  final List<ui.Offset> stars;
  final double progress;

  StarFieldPainter({required this.stars, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    final r = math.Random(42);

    for (int i = 0; i < stars.length; i++) {
      final star = stars[i];
      final pulse = math.sin((progress * 2 * math.pi) + r.nextDouble() * 10);
      final opacity = 0.15 + (pulse.abs() * 0.45);
      final radius = 1.0 + (pulse.abs() * 1.5);
      
      paint.color = Colors.white.withOpacity(opacity);
      canvas.drawCircle(star, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
