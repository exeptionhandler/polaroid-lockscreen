import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Removed wallpaperMain as it was moved to main.dart

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

class _PolaroidWallpaperPageState extends State<PolaroidWallpaperPage> with SingleTickerProviderStateMixin {
  static const _channel = MethodChannel('com.stick.polaroid/wallpaper');
  
  List<ui.Image> _loadedImages = [];
  bool _isLoading = true;
  bool _isVisible = true;
  String _loveNote = 'Te amo ❤️';

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
    
    // Smooth high-refresh-rate animation controller
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 16),
    )..addListener(_tick);

    _setupMethodChannel();
    _loadImages();
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

  Future<void> _loadImages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final paths = prefs.getStringList('selected_images') ?? [];
      final loveNote = prefs.getString('love_note') ?? 'Te amo ❤️';
      
      final List<ui.Image> images = [];
      for (final path in paths) {
        if (await File(path).exists()) {
          final image = await _loadImage(path);
          images.add(image);
        }
      }

      setState(() {
        _loadedImages = images;
        _loveNote = loveNote;
        _isLoading = false;
      });

      // Wait until screen size is known to initialize particles
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _initializeParticles();
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      _initializeParticles();
    }
  }

  Future<ui.Image> _loadImage(String path) async {
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  void _initializeParticles() {
    if (_screenSize == Size.zero) return;
    
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
      final speed = 40.0 + _random.nextDouble() * 40.0; // pixels per second
      final vx = math.cos(angle) * speed;
      final vy = math.sin(angle) * speed;

      _particles.add(
        PolaroidParticle(
          x: x,
          y: y,
          vx: vx,
          vy: vy,
          angle: (_random.nextDouble() - 0.5) * 0.4, // subtle initial tilt
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
    // Restart animation, reset timeline, randomize positions
    _initializeParticles();
  }

  void _pausePhysics() {
    _controller.stop();
  }

  void _handleTouch(double tx, double ty) {
    if (_isSelecting) return;
    
    // Give all nearby particles a gentle physical push away from the touch point
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
      // Start selection process after 2.5 seconds
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
      _selectionProgress += dt * 1.2; // complete zoom in ~0.8s
      if (_selectionProgress >= 1.0) {
        _selectionProgress = 1.0;
        _controller.stop(); // Stop physics engine completely to save battery
      }
    }

    // 1. Position Updates
    for (int i = 0; i < _particles.length; i++) {
      final p = _particles[i];
      
      if (i == _selectedIdx && _isSelecting) {
        // Selected Polaroid: Smooth bezier / curved interpolation to center
        final t = Curves.easeInOut.transform(_selectionProgress);
        final targetX = _screenSize.width / 2;
        final targetY = _screenSize.height / 2;
        
        p.x = ui.lerpDouble(p.startX, targetX, t)!;
        p.y = ui.lerpDouble(p.startY, targetY, t)!;
        p.angle = ui.lerpDouble(p.startAngle, 0.0, t)!;
        p.scale = ui.lerpDouble(1.0, 2.3, t)!;
      } else {
        // Floating Polaroids: Update using standard velocity vectors
        p.x += p.vx * dt;
        p.y += p.vy * dt;
        p.angle += p.vAngle * dt;

        // Limit speed to prevent chaotic collisions
        final speed = math.sqrt(p.vx * p.vx + p.vy * p.vy);
        if (speed > 150.0) {
          p.vx = (p.vx / speed) * 150.0;
          p.vy = (p.vy / speed) * 150.0;
        }
        
        // Dynamic angular damping
        p.vAngle *= 0.98;

        // 2. Edge Bounces
        final rad = p.radius;
        if (p.x - rad < 0) {
          p.x = rad;
          p.vx = p.vx.abs() * 0.95; // highly elastic
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

    // 3. Elastic Collisions between particles (exclude selected particle)
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
          // Resolve overlap to prevent sticky elements
          final overlap = minDist - dist;
          final resolveX = (dx / dist) * overlap * 0.5;
          final resolveY = (dy / dist) * overlap * 0.5;
          
          p1.x -= resolveX;
          p1.y -= resolveY;
          p2.x += resolveX;
          p2.y += resolveY;

          // Elastic 2D physics math
          final nx = dx / dist;
          final ny = dy / dist;
          
          // Relative velocity
          final rvx = p2.vx - p1.vx;
          final rvy = p2.vy - p1.vy;
          
          // Velocity along the normal
          final velAlongNormal = rvx * nx + rvy * ny;
          
          // Only resolve if velocities are approaching each other
          if (velAlongNormal < 0) {
            final impulse = -(1.0 + 0.9) * velAlongNormal / (1 / p1.mass + 1 / p2.mass);
            
            p1.vx -= (impulse / p1.mass) * nx;
            p1.vy -= (impulse / p1.mass) * ny;
            
            p2.vx += (impulse / p2.mass) * nx;
            p2.vy += (impulse / p2.mass) * ny;
            
            // Random spin addition
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
    return LayoutBuilder(
      builder: (context, constraints) {
        if (_screenSize != Size(constraints.maxWidth, constraints.maxHeight)) {
          _screenSize = Size(constraints.maxWidth, constraints.maxHeight);
          // Initialize/reposition if resized
          _initializeParticles();
        }

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFF0F0B1E), // Soft dark purple/night
                  Color(0xFF1E1735),
                  Color(0xFF2E2248),
                ],
              ),
            ),
            child: Stack(
              children: [
                // Aesthetic starfield/sparkles background
                const Positioned.fill(
                  child: StarFieldWidget(),
                ),
                if (_isLoading)
                  const Center(
                    child: CircularProgressIndicator(
                      color: Color(0xFFFF6B8B),
                    ),
                  )
                else
                  CustomPaint(
                    size: Size.infinite,
                    painter: PolaroidPhysicsPainter(
                      particles: _particles,
                      selectedIdx: _selectedIdx,
                      isSelecting: _isSelecting,
                      selectionProgress: _selectionProgress,
                      loveNote: _loveNote,
                    ),
                  ),
              ],
            ),
          ),
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

    // 2. Paint selected particle on top so it stands out while zooming
    if (selectedIdx != -1 && selectedIdx < particles.length) {
      // Draw a dark overlay behind the zoomed Polaroid for dramatic effect
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
    
    // Translate and rotate
    canvas.translate(p.x, p.y);
    canvas.rotate(p.angle);
    canvas.scale(p.scale);

    // Standard Polaroid dimensions (110x132)
    final w = 110.0;
    final h = 132.0;
    final rect = Rect.fromLTWH(-w / 2, -h / 2, w, h);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(4.0));

    // 1. Draw subtle elevation drop-shadow
    final shadowPaint = Paint()
      ..color = Colors.black.withOpacity(0.35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5.0);
    canvas.drawRRect(rrect.shift(const Offset(2.0, 4.0)), shadowPaint);

    // 2. Draw white Polaroid border/frame
    final framePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawRRect(rrect, framePaint);

    // 3. Draw standard Polaroid picture area (top-centered square: 94x94)
    final imgW = 94.0;
    final imgH = 94.0;
    final imgRect = Rect.fromLTWH(-imgW / 2, -h / 2 + 8.0, imgW, imgH);
    final imgRRect = RRect.fromRectAndRadius(imgRect, const Radius.circular(2.0));

    if (p.image != null) {
      // Crop image to square aspect ratio elastically
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
      // Default romantic placeholder: pink/purple gradient with red heart
      final gradientPaint = Paint()
        ..shader = ui.Gradient.linear(
          imgRect.topLeft,
          imgRect.bottomRight,
          [const Color(0xFFFFB5C5), const Color(0xFFC7A2E5)],
        );
      canvas.drawRRect(imgRRect, gradientPaint);

      // Draw cute handwritten style heart
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

    // 4. Draw a small romantic note / heart at the bottom
    _drawPolaroidNote(canvas, w, h, p.index, p.index == selectedIdx && isSelecting);

    canvas.restore();
  }

  void _drawPolaroidNote(Canvas canvas, double w, double h, int index, bool isZoomed) {
    if (isZoomed && loveNote.isNotEmpty) {
      // Draw elegant customized text for the zoomed photo
      final textPainter = TextPainter(
        text: TextSpan(
          text: loveNote,
          style: const TextStyle(
            color: Color(0xFFFF4B72),
            fontSize: 6.0,
            fontWeight: FontWeight.w600,
            fontFamily: 'sans-serif', // Clean elegant fallback font
            fontStyle: FontStyle.italic,
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout(maxWidth: w - 16.0);
      
      // Calculate drawing offset so it fits perfectly in the bottom margin of the Polaroid
      final cx = 0.0;
      final cy = h / 2 - 20.0;
      textPainter.paint(canvas, Offset(cx - textPainter.width / 2, cy));
    } else {
      // Elegant tiny heart or quote under the picture
      final heartPaint = Paint()
        ..color = const Color(0xFFFF6B8B).withOpacity(0.8)
        ..style = PaintingStyle.fill;

      // Draw three cute mini dots or a tiny heart in the bottom margin
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

// Sparkly aesthetic animated stars for premium feel
class StarFieldWidget extends StatefulWidget {
  const StarFieldWidget({Key? key}) : super(key: key);

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
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_stars.isEmpty) {
      final size = MediaQuery.of(context).size;
      for (int i = 0; i < 40; i++) {
        _stars.add(ui.Offset(
          _random.nextDouble() * size.width,
          _random.nextDouble() * size.height,
        ));
      }
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
    final r = math.Random(42); // stable random seed for matching index twinkling

    for (int i = 0; i < stars.length; i++) {
      final star = stars[i];
      // Twinkling effect
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
