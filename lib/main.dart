import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// Import wallpaper entrypoint so it is not pruned by compiler
import 'wallpaper.dart';

/// Helper to log from Dart to the native log file
const _logChannel = MethodChannel('com.stick.polaroid/wallpaper');
void _dartLog(String msg) {
  try {
    _logChannel.invokeMethod('writeLog', msg);
  } catch (_) {}
}

@pragma('vm:entry-point')
void wallpaperMain() {
  WidgetsFlutterBinding.ensureInitialized();
  _dartLog('wallpaperMain: ENTERED');
  
  runZonedGuarded(() {
    _dartLog('wallpaperMain: runZonedGuarded started');
    _dartLog('wallpaperMain: WidgetsFlutterBinding initialized');
    
    ErrorWidget.builder = (FlutterErrorDetails details) {
      _dartLog('ErrorWidget: ${details.exceptionAsString()}');
      return Container(
        color: const Color(0xFF1E1735),
        child: Center(
          child: Text(
            'Error: ${details.exceptionAsString()}',
            style: const TextStyle(color: Color(0xFFFF6B8B), fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ),
      );
    };
    
    FlutterError.onError = (FlutterErrorDetails details) {
      _dartLog('FlutterError: ${details.exceptionAsString()}');
      _logChannel.invokeMethod('showToast', details.exceptionAsString());
    };
    
    _dartLog('wallpaperMain: calling runApp');
    runApp(const MaterialApp(
      home: PolaroidWallpaperPage(),
      debugShowCheckedModeBanner: false,
    ));
    _dartLog('wallpaperMain: runApp completed');
  }, (error, stackTrace) {
    _dartLog('ZONE ERROR: $error\n$stackTrace');
    _logChannel.invokeMethod('showToast', 'Async Error: $error');
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LiquidGlassWidgets.initialize();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return LiquidGlassWidgets.wrap(
      adaptiveQuality: true,
      theme: GlassThemeData.simple(
        blur: 12,
        thickness: 35,
        quality: GlassQuality.standard,
      ),
      child: MaterialApp(
        title: 'Polaroid Lockscreen',
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: Colors.transparent,
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFFFF6B8B),
            secondary: Color(0xFFFFD166),
            surface: Color(0xFF1E1735),
          ),
          useMaterial3: true,
        ),
        home: const MainConfigPage(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}

class MainConfigPage extends StatefulWidget {
  const MainConfigPage({super.key});

  @override
  State<MainConfigPage> createState() => _MainConfigPageState();
}

class _MainConfigPageState extends State<MainConfigPage>
    with SingleTickerProviderStateMixin {
  static const _configChannel =
      MethodChannel('com.stick.polaroid/wallpaper_config');
  final ImagePicker _picker = ImagePicker();
  List<String> _imagePaths = [];
  bool _isLoading = true;
  String _loveNote = 'Nuestros momentos más felices... ¡Te amo! ❤️';
  final TextEditingController _loveNoteController = TextEditingController();
  String _polaroidEmoji = '❤️';
  final TextEditingController _emojiController = TextEditingController();

  late AnimationController _bgAnimController;

  @override
  void initState() {
    super.initState();
    _bgAnimController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
    _loadSavedImages();
  }

  @override
  void dispose() {
    _loveNoteController.dispose();
    _emojiController.dispose();
    _bgAnimController.dispose();
    super.dispose();
  }

  Future<void> _loadSavedImages() async {
    final prefs = await SharedPreferences.getInstance();
    final paths = prefs.getStringList('selected_images') ?? [];
    final loveNote = prefs.getString('love_note') ??
        'Nuestros momentos más felices... ¡Te amo! ❤️';
    final polaroidEmoji = prefs.getString('polaroid_emoji') ?? '❤️';

    final List<String> validPaths = [];
    for (final path in paths) {
      if (await File(path).exists()) {
        validPaths.add(path);
      }
    }

    if (validPaths.length != paths.length) {
      await prefs.setStringList('selected_images', validPaths);
    }

    setState(() {
      _imagePaths = validPaths;
      _loveNote = loveNote;
      _loveNoteController.text = loveNote;
      _polaroidEmoji = polaroidEmoji;
      _emojiController.text = polaroidEmoji;
      _isLoading = false;
    });
  }

  Future<void> _addImages() async {
    try {
      final List<XFile> pickedFiles = await _picker.pickMultiImage(
        imageQuality: 85,
        maxWidth: 1000,
        maxHeight: 1000,
      );

      if (pickedFiles.isEmpty) return;

      setState(() => _isLoading = true);

      final directory = await getApplicationDocumentsDirectory();
      final prefs = await SharedPreferences.getInstance();

      final List<String> newPaths = List.from(_imagePaths);

      for (final file in pickedFiles) {
        final fileName =
            'polaroid_${DateTime.now().millisecondsSinceEpoch}_${math.Random().nextInt(1000)}.jpg';
        final savedFile =
            await File(file.path).copy('${directory.path}/$fileName');
        newPaths.add(savedFile.path);
      }

      await prefs.setStringList('selected_images', newPaths);

      setState(() {
        _imagePaths = newPaths;
        _isLoading = false;
      });

      _showSnackBar('¡Fotos añadidas con éxito! ❤️');
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnackBar('Error al seleccionar fotos: $e 😢');
    }
  }

  Future<void> _removeImage(int index) async {
    try {
      final file = File(_imagePaths[index]);
      if (await file.exists()) {
        await file.delete();
      }

      final List<String> newPaths = List.from(_imagePaths)..removeAt(index);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('selected_images', newPaths);

      setState(() => _imagePaths = newPaths);

      _showSnackBar('Foto eliminada 💔');
    } catch (e) {
      _showSnackBar('Error al eliminar foto 😢');
    }
  }

  Future<void> _launchWallpaperChooser() async {
    if (_imagePaths.isEmpty) {
      _showSnackBar('Añade al menos una foto primero uwu');
      return;
    }

    try {
      final bool success =
          await _configChannel.invokeMethod('openWallpaperChooser');
      if (!success) {
        _showSnackBar('No se pudo abrir el selector de fondos 😢');
      }
    } catch (e) {
      _showSnackBar('Error de plataforma: $e 😢');
    }
  }

  Future<void> _showWallpaperLogs() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final logPath = directory.path
          .replaceAll('/app_flutter', '/files/wallpaper_log.txt');
      final logFile = File(logPath);

      String logContent;
      if (await logFile.exists()) {
        logContent = await logFile.readAsString();
      } else {
        logContent =
            'No hay logs todavía.\n\nEl archivo de log se crea cuando el servicio de wallpaper se inicia.\n\nRuta buscada: $logPath';
      }

      if (!mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF1E1735).withOpacity(0.92),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(
            children: [
              Icon(Icons.bug_report, color: Color(0xFFFFD166), size: 22),
              SizedBox(width: 8),
              Text('Wallpaper Logs 🔍',
                  style: TextStyle(color: Colors.white, fontSize: 16)),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: SingleChildScrollView(
              reverse: true,
              child: SelectableText(
                logContent,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontFamily: 'monospace',
                  height: 1.4,
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cerrar',
                  style: TextStyle(color: Color(0xFFFF6B8B))),
            ),
          ],
        ),
      );
    } catch (e) {
      _showSnackBar('Error leyendo logs: $e');
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: const Color(0xFFFF6B8B).withOpacity(0.9),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showEditLoveNoteDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1735).withOpacity(0.92),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: const Row(
            children: [
              Icon(Icons.edit_note_rounded, color: Color(0xFFFF6B8B)),
              SizedBox(width: 10),
              Text(
                'Personalizar 💌',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Mensaje de amor (al pie de foto grande):',
                style: TextStyle(
                    color: Colors.white70, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _loveNoteController,
                maxLines: 2,
                maxLength: 60,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF0F0B1E),
                  hintText: 'Ej. ¡Eres el amor de mi vida! ❤️',
                  hintStyle: const TextStyle(color: Colors.white30),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide:
                        const BorderSide(color: Color(0xFFFF6B8B), width: 1.5),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Colors.white10),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Emoji pequeño (en fotos flotantes):',
                style: TextStyle(
                    color: Colors.white70, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _emojiController,
                maxLength: 2,
                style: const TextStyle(color: Colors.white, fontSize: 22),
                textAlign: TextAlign.center,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF0F0B1E),
                  hintText: '❤️',
                  hintStyle: const TextStyle(color: Colors.white30),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide:
                        const BorderSide(color: Color(0xFFFF6B8B), width: 1.5),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Colors.white10),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child:
                  const Text('Cancelar', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              onPressed: () async {
                final navigator = Navigator.of(context);
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString('love_note', _loveNoteController.text);
                await prefs.setString(
                    'polaroid_emoji', _emojiController.text);
                setState(() {
                  _loveNote = _loveNoteController.text;
                  _polaroidEmoji = _emojiController.text;
                });
                if (mounted) {
                  navigator.pop();
                  _showSnackBar('¡Actualizado! 💌');
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF6B8B),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('Guardar'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return GlassPage(
      background: AnimatedBuilder(
        animation: _bgAnimController,
        builder: (context, child) {
          return Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment(
                  math.cos(_bgAnimController.value * 2 * math.pi) * 0.5,
                  math.sin(_bgAnimController.value * 2 * math.pi) * 0.5,
                ),
                end: Alignment(
                  math.cos((_bgAnimController.value + 0.5) * 2 * math.pi) *
                      0.5,
                  math.sin((_bgAnimController.value + 0.5) * 2 * math.pi) *
                      0.5,
                ),
                colors: const [
                  Color(0xFF0F0B1E),
                  Color(0xFF1A1040),
                  Color(0xFF2A1E55),
                  Color(0xFF3D2E6E),
                  Color(0xFF1A1040),
                ],
                stops: const [0.0, 0.25, 0.5, 0.75, 1.0],
              ),
            ),
          );
        },
      ),
      edgeToEdge: true,
      statusBarStyle: GlassStatusBarStyle.light,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: _isLoading
            ? const Center(
                child: CircularProgressIndicator(
                  color: Color(0xFFFF6B8B),
                ),
              )
            : SafeArea(
                child: CustomScrollView(
                  physics: const BouncingScrollPhysics(),
                  slivers: [
                    // ── Glass App Bar ──
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: GlassContainer(
                          shape: const LiquidRoundedSuperellipse(borderRadius: 22),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          child: Row(
                            children: [
                              const Icon(Icons.favorite_rounded,
                                  color: Color(0xFFFF6B8B), size: 28),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: Text(
                                  'Polaroid Lockscreen',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ),
                              GlassButton(
                                icon: const Icon(Icons.bug_report_outlined,
                                    color: Colors.white54, size: 20),
                                onTap: _showWallpaperLogs,
                                width: 40,
                                height: 40,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    const SliverToBoxAdapter(child: SizedBox(height: 16)),

                    // ── Dedication Card ──
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: GlassCard(
                          shape: const LiquidRoundedSuperellipse(borderRadius: 22),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFF6B8B)
                                        .withOpacity(0.25),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Text(
                                    _polaroidEmoji.isNotEmpty
                                        ? _polaroidEmoji
                                        : '❤️',
                                    style: const TextStyle(fontSize: 22),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'Dedicatoria Especial 💌',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        _loveNote,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFFFFB5C5),
                                          fontStyle: FontStyle.italic,
                                          fontWeight: FontWeight.w500,
                                          height: 1.4,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                GlassButton(
                                  icon: const Icon(Icons.edit_note_rounded,
                                      color: Color(0xFFFFD166), size: 26),
                                  onTap: _showEditLoveNoteDialog,
                                  width: 44,
                                  height: 44,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                    const SliverToBoxAdapter(child: SizedBox(height: 20)),

                    // ── Section Title ──
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          children: [
                            const Icon(Icons.photo_library_rounded,
                                color: Colors.white54, size: 18),
                            const SizedBox(width: 8),
                            const Text(
                              'Tus Momentos',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: Colors.white70,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '${_imagePaths.length} fotos',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.white.withOpacity(0.4),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SliverToBoxAdapter(child: SizedBox(height: 12)),

                    // ── Photo Grid or Empty State ──
                    if (_imagePaths.isEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: GlassCard(
                            shape: const LiquidRoundedSuperellipse(borderRadius: 22),
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: Column(
                                children: [
                                  Icon(
                                    Icons.photo_library_outlined,
                                    size: 56,
                                    color: const Color(0xFFFFD166)
                                        .withOpacity(0.7),
                                  ),
                                  const SizedBox(height: 16),
                                  const Text(
                                    'Aún no hay recuerdos',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  const Text(
                                    'Toca el botón de abajo para elegir tus fotos favoritas 📸',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.white60,
                                      height: 1.4,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        sliver: SliverGrid(
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 14,
                            mainAxisSpacing: 14,
                            childAspectRatio: 0.78,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            (context, index) =>
                                _buildPolaroidGridItem(index),
                            childCount: _imagePaths.length,
                          ),
                        ),
                      ),

                    // Bottom spacing for buttons
                    const SliverToBoxAdapter(child: SizedBox(height: 160)),
                  ],
                ),
              ),

        // ── Bottom Action Buttons ──
        bottomNavigationBar: Container(
          padding:
              EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 12, left: 16, right: 16, top: 10),
          child: Row(
            children: [
              // Apply wallpaper button
              Expanded(
                child: GlassButton.custom(
                  onTap: _launchWallpaperChooser,
                  width: double.infinity,
                  height: 52,
                  shape: const LiquidRoundedSuperellipse(borderRadius: 18),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.wallpaper_rounded,
                          color: Color(0xFFFFD166), size: 20),
                      SizedBox(width: 8),
                      Text(
                        'Aplicar Fondo 💖',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Add photos button
              GlassButton.custom(
                onTap: _addImages,
                width: 120,
                height: 52,
                shape: const LiquidRoundedSuperellipse(borderRadius: 18),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_photo_alternate_rounded,
                        color: Color(0xFFFF6B8B), size: 22),
                    SizedBox(width: 6),
                    Text(
                      'Añadir',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPolaroidGridItem(int index) {
    return GlassContainer(
      shape: const LiquidRoundedSuperellipse(borderRadius: 16),
      child: Column(
        children: [
          // Square cropped photo
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        File(_imagePaths[index]),
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
                // Delete button
                Positioned(
                  top: 8,
                  right: 8,
                  child: GestureDetector(
                    onTap: () => _removeImage(index),
                    child: Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF4B72).withOpacity(0.9),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.3),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.close_rounded,
                        color: Colors.white,
                        size: 14,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Heart / Emoji bottom
          Padding(
            padding: const EdgeInsets.only(bottom: 6, top: 2),
            child: Text(
              _polaroidEmoji.isNotEmpty ? _polaroidEmoji : '❤️',
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}
