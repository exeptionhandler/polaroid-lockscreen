import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Import wallpaper entrypoint so it is not pruned by compiler
import 'wallpaper.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Reference wallpaperMain to prevent compile-time tree-shaking
  if (DateTime.now().year < 2000) {
    wallpaperMain();
  }
  
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Polaroid Lockscreen',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F0B1E),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF6B8B),
          secondary: Color(0xFFFFD166),
          background: Color(0xFF0F0B1E),
          surface: Color(0xFF1E1735),
        ),
        useMaterial3: true,
      ),
      home: const MainConfigPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MainConfigPage extends StatefulWidget {
  const MainConfigPage({Key? key}) : super(key: key);

  @override
  State<MainConfigPage> createState() => _MainConfigPageState();
}

class _MainConfigPageState extends State<MainConfigPage> {
  static const _configChannel = MethodChannel('com.stick.polaroid/wallpaper_config');
  final ImagePicker _picker = ImagePicker();
  List<String> _imagePaths = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSavedImages();
  }

  Future<void> _loadSavedImages() async {
    final prefs = await SharedPreferences.getInstance();
    final paths = prefs.getStringList('selected_images') ?? [];
    
    // Verify files still exist, clean up if deleted
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
      _isLoading = false;
    });
  }

  Future<void> _addImages() async {
    try {
      final List<XFile> pickedFiles = await _picker.pickMultiImage(
        imageQuality: 85, // Optimize size
        maxWidth: 1000,
        maxHeight: 1000,
      );

      if (pickedFiles.isEmpty) return;

      setState(() {
        _isLoading = true;
      });

      final directory = await getApplicationDocumentsDirectory();
      final prefs = await SharedPreferences.getInstance();
      
      final List<String> newPaths = List.from(_imagePaths);

      for (final file in pickedFiles) {
        // Copy picked image to app permanent storage
        final fileName = 'polaroid_${DateTime.now().millisecondsSinceEpoch}_${math.Random().nextInt(1000)}.jpg';
        final savedFile = await File(file.path).copy('${directory.path}/$fileName');
        newPaths.add(savedFile.path);
      }

      await prefs.setStringList('selected_images', newPaths);

      setState(() {
        _imagePaths = newPaths;
        _isLoading = false;
      });

      _showSnackBar('¡Fotos añadidas con éxito! ❤️');
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
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

      setState(() {
        _imagePaths = newPaths;
      });

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
      final bool success = await _configChannel.invokeMethod('openWallpaperChooser');
      if (!success) {
        _showSnackBar('No se pudo abrir el selector de fondos 😢');
      }
    } catch (e) {
      _showSnackBar('Error de plataforma: $e 😢');
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
        backgroundColor: const Color(0xFFFF6B8B),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Polaroid Lockscreen ❤️',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            letterSpacing: 0.8,
            color: Colors.white,
          ),
        ),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(
                color: Color(0xFFFF6B8B),
              ),
            )
          : Container(
              width: double.infinity,
              height: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  // Romantic Header Card
                  _buildHeaderCard(),
                  const SizedBox(height: 20),
                  const Text(
                    'Tus Momentos Seleccionados',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Colors.white70,
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Grid / Empty State
                  Expanded(
                    child: _imagePaths.isEmpty
                        ? _buildEmptyState()
                        : _buildPhotoGrid(),
                  ),
                  const SizedBox(height: 80), // Space for floating button
                ],
              ),
            ),
      bottomSheet: _buildBottomActions(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addImages,
        backgroundColor: const Color(0xFFFF6B8B),
        foregroundColor: Colors.white,
        elevation: 6,
        icon: const Icon(Icons.add_photo_alternate_rounded, size: 24),
        label: const Text(
          'Añadir Fotos',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endContained,
    );
  }

  Widget _buildHeaderCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFFFF6B8B).withOpacity(0.15),
            const Color(0xFFC7A2E5).withOpacity(0.15),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFFFF6B8B).withOpacity(0.3),
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFFF6B8B).withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.favorite_rounded,
              color: Color(0xFFFF6B8B),
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Un Regalo Mágico ✨',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Elige tus fotos favoritas. Flotarán en gravedad cero al estilo Polaroid y una se acercará cada vez que enciendas la pantalla.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white70,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(24),
        margin: const EdgeInsets.only(bottom: 40),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1735).withOpacity(0.6),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.photo_library_outlined,
              size: 64,
              color: const Color(0xFFFFD166).withOpacity(0.8),
            ),
            const SizedBox(height: 16),
            const Text(
              'Aún no hay recuerdos agregados',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Toca el botón rosa de abajo para elegir fotos bonitas de la galería de tu celular.',
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
    );
  }

  Widget _buildPhotoGrid() {
    return GridView.builder(
      physics: const BouncingScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
        childAspectRatio: 0.8, // standard Polaroid ratio
      ),
      itemCount: _imagePaths.length,
      itemBuilder: (context, index) {
        return _buildPolaroidGridItem(index);
      },
    );
  }

  Widget _buildPolaroidGridItem(int index) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 8,
            offset: const Offset(2, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          // Square cropped photo
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.file(
                      File(_imagePaths[index]),
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                // Premium delete ribbon/overlay
                Positioned(
                  top: 4,
                  right: 4,
                  child: GestureDetector(
                    onTap: () => _removeImage(index),
                    child: Container(
                      padding: const EdgeInsets.all(5),
                      decoration: const BoxDecoration(
                        color: Color(0xFFFF4B72),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.delete_rounded,
                        color: Colors.white,
                        size: 16,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Heart bottom bar to look exactly like a Polaroid
          Container(
            height: 16,
            alignment: Alignment.center,
            child: const Icon(
              Icons.favorite_rounded,
              color: Color(0xFFFF6B8B),
              size: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomActions() {
    return Container(
      color: const Color(0xFF0F0B1E),
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 20, top: 12),
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _launchWallpaperChooser,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1E1735),
                foregroundColor: const Color(0xFFFFD166),
                padding: const EdgeInsets.symmetric(vertical: 16),
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: const Color(0xFFFFD166).withOpacity(0.4),
                    width: 1,
                  ),
                ),
              ),
              icon: const Icon(Icons.wallpaper_rounded, color: Color(0xFFFFD166)),
              label: const Text(
                'Aplicar Fondo de Pantalla 💖',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ),
          const SizedBox(width: 140), // Room for FAB
        ],
      ),
    );
  }
}
