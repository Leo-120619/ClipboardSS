import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import 'core/app_state.dart';
import 'core/clip_sender.dart';
import 'core/content_hasher.dart';
import 'core/models.dart';
import 'desktop/clipboard_sync_service.dart';
import 'desktop/desktop_shell.dart';
import 'desktop/windows_clipboard.dart';

const _logoAsset = '../Assets/clipboard.png';

/// Auto-sync service driving the Windows clipboard; null on mobile.
ClipboardSyncService? desktopSyncService;

class AppColors {
  static const background = Color(0xFF202529);
  static const panel = Color(0xFF2B3033);
  static const panelElevated = Color(0xFF30363A);
  static const latest = Color(0xFF203047);
  static const control = Color(0xFF343A40);
  static const selected = Color(0xFF5B6063);
  static const text = Color(0xFFE7E8EA);
  static const muted = Color(0xFFA8ADB2);
  static const faint = Color(0xFF737A81);
  static const accent = Color(0xFF41B7FF);
  static const danger = Color(0xFFE06C75);
}

enum MobileClipFilter { all, text, images, pinned }

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();

  final appState = AppState();
  await appState.init(prefs);

  if (Platform.isWindows) {
    final syncService = ClipboardSyncService(
      clipboard: MethodChannelWindowsClipboard(),
      deviceName: appState.identity.name,
      broadcast: appState.sendClip,
      topClipHash: () =>
          appState.clips.isEmpty ? null : appState.clips.first.contentHash,
    );
    appState.onClipReceived = syncService.writeIncoming;
    syncService.start();
    desktopSyncService = syncService;
    await DesktopShell.init(
      appState,
      copyToClipboard: syncService.writeIncoming,
    );
  }

  runApp(
    ChangeNotifierProvider.value(
      value: appState,
      child: const ClipboardCompanionApp(),
    ),
  );
}

class ClipboardCompanionApp extends StatelessWidget {
  const ClipboardCompanionApp({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = GoogleFonts.plusJakartaSansTextTheme(
      Theme.of(context).textTheme,
    );

    return MaterialApp(
      title: 'Clipboard Companion',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.accent,
          secondary: AppColors.muted,
          surface: AppColors.panel,
          onSurface: AppColors.text,
          error: AppColors.danger,
        ),
        scaffoldBackgroundColor: AppColors.background,
        textTheme: textTheme.apply(
          bodyColor: AppColors.text,
          displayColor: AppColors.text,
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: AppColors.background,
          elevation: 0,
          scrolledUnderElevation: 0,
          iconTheme: const IconThemeData(color: AppColors.text),
          titleTextStyle: textTheme.titleLarge?.copyWith(
            color: AppColors.text,
            fontWeight: FontWeight.w600,
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          color: AppColors.panel,
          margin: EdgeInsets.zero,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            textStyle: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          elevation: 0,
          hoverElevation: 0,
          focusElevation: 0,
          highlightElevation: 0,
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        dialogTheme: DialogThemeData(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          elevation: 0,
          backgroundColor: AppColors.panelElevated,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const MethodChannel _imagesChannel = MethodChannel(
    'clipboard_companion/images',
  );
  final TextEditingController _searchController = TextEditingController();
  MobileClipFilter _selectedFilter = MobileClipFilter.all;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<AppState>().startSyncServices();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Desktop keeps syncing while hidden in the tray; only mobile pauses
    // networking when backgrounded.
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) return;
    final appState = context.read<AppState>();
    switch (state) {
      case AppLifecycleState.resumed:
        appState.resumeSyncServices();
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        appState.pauseSyncServices();
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _MacHeader(
              searchController: _searchController,
              selectedFilter: _selectedFilter,
              canClear: state.clips.isNotEmpty,
              onSearchChanged: (_) => setState(() {}),
              onFilterChanged: (filter) {
                setState(() => _selectedFilter = filter);
              },
              onDevicesPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DevicesScreen()),
                );
              },
              onClearPressed: () => _confirmClearClips(context, state),
            ),
            const Divider(height: 1, color: Color(0xFF3A4046)),
            Expanded(child: _bodyFor(state)),
          ],
        ),
      ),
      floatingActionButton: state.isReady
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FloatingActionButton.small(
                  heroTag: 'send_image',
                  onPressed: () => _pickAndSendImage(context, state),
                  tooltip: 'Send Image',
                  child: const Icon(Icons.image_rounded),
                ),
                const SizedBox(height: 16),
                FloatingActionButton.extended(
                  heroTag: 'send_clipboard',
                  onPressed: () => _showSendClipboardSheet(context, state),
                  icon: const Icon(Icons.send_rounded),
                  label: const Text(
                    'Send Clipboard',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            )
          : null,
    );
  }

  Widget _bodyFor(AppState state) {
    if (state.syncPermissionDenied) {
      return _buildEmptyState(
        icon: Icons.wifi_tethering_error_rounded,
        title: 'Permission Denied',
        description:
            'Nearby device permission is required to sync clips seamlessly.',
        actionLabel: 'Allow Sync',
        onAction: state.retrySyncServices,
      );
    }

    if (state.startupError != null) {
      return _buildEmptyState(
        icon: Icons.error_outline_rounded,
        title: 'Sync Error',
        description: 'Could not start sync services:\n${state.startupError}',
        actionLabel: 'Retry',
        onAction: state.retrySyncServices,
        isError: true,
      );
    }

    if (state.isStartingSync || !state.isReady) {
      return const Center(child: CircularProgressIndicator());
    }

    return state.clips.isEmpty
        ? _buildEmptyState(
            icon: Icons.content_paste_off_rounded,
            title: 'No clips yet',
            description:
                'Send items from your Mac or other devices, and they will appear here.',
          )
        : _buildClipList(context, state);
  }

  Widget _buildClipList(BuildContext context, AppState state) {
    final clips = _filteredClips(state.clips);
    if (clips.isEmpty) {
      return _buildEmptyState(
        icon: Icons.manage_search_rounded,
        title: 'No matching clips',
        description: 'Adjust the search or filter to find a saved clip.',
      );
    }

    final latest = clips.first;
    final history = clips.skip(1).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 104),
      children: [
        const _SectionHeader(title: 'Latest'),
        const SizedBox(height: 10),
        ReceivedClipTile(
          clip: latest,
          isProminent: true,
          onCopyImage: _copyImageToClipboard,
          onDelete: () => _deleteClip(context, state, latest),
        ),
        const SizedBox(height: 26),
        const _SectionHeader(title: 'History'),
        const SizedBox(height: 10),
        if (history.isEmpty)
          Text(
            'No older clips',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: AppColors.muted,
              fontWeight: FontWeight.w600,
            ),
          )
        else
          for (final clip in history) ...[
            ReceivedClipTile(
              clip: clip,
              onCopyImage: _copyImageToClipboard,
              onDelete: () => _deleteClip(context, state, clip),
            ),
            if (clip != history.last) const SizedBox(height: 12),
          ],
      ],
    );
  }

  List<ClipPayload> _filteredClips(List<ClipPayload> clips) {
    final query = _searchController.text.trim().toLowerCase();
    return clips.where((clip) {
      final matchesFilter = switch (_selectedFilter) {
        MobileClipFilter.all => true,
        MobileClipFilter.text => clip.type == ClipType.text,
        MobileClipFilter.images => clip.type == ClipType.image,
        MobileClipFilter.pinned => false,
      };
      if (!matchesFilter) return false;
      if (query.isEmpty) return true;

      final searchable = [
        clip.text,
        clip.previewText,
        clip.sourceDeviceName,
        clip.type.name,
      ].whereType<String>().join(' ').toLowerCase();
      return searchable.contains(query);
    }).toList();
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String description,
    String? actionLabel,
    VoidCallback? onAction,
    bool isError = false,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isError
                    ? Theme.of(context).colorScheme.error.withValues(alpha: 0.1)
                    : AppColors.panelElevated,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 48,
                color: isError
                    ? Theme.of(context).colorScheme.error
                    : AppColors.muted,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              description,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.muted,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 24),
              FilledButton(onPressed: onAction, child: Text(actionLabel)),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _deleteClip(
    BuildContext context,
    AppState state,
    ClipPayload clip,
  ) async {
    await state.deleteClip(clip.id);
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Clip deleted'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _confirmClearClips(BuildContext context, AppState state) async {
    final shouldClear = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete all clips?'),
          content: const Text('This removes every saved clip from this phone.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.delete_sweep_rounded),
              label: const Text('Delete all'),
            ),
          ],
        );
      },
    );

    if (shouldClear != true) return;
    await state.clearClips();
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('All clips deleted'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _copyImageToClipboard(ClipPayload clip) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final syncService = desktopSyncService;
      if (Platform.isWindows && syncService != null) {
        await syncService.writeIncoming(clip);
      } else {
        await _imagesChannel.invokeMethod<void>('copyImageToClipboard', {
          'imageBase64': clip.imageBase64,
          'extension': clip.imageExtension ?? 'png',
        });
      }
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Copied image to clipboard'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Could not copy image: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _showSendClipboardSheet(BuildContext context, AppState state) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final initialText = data?.text ?? '';

    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return ClipboardSendSheet(
          initialText: initialText,
          onSend: (text) async {
            final clip = ClipPayload(
              id: const Uuid().v4(),
              type: ClipType.text,
              createdAt: DateTime.now(),
              text: text,
              contentHash: ContentHasher.textHash(text),
              sourceDeviceName: state.identity.name,
            );
            final sendSummary = await state.sendClip(clip);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(_sendSummaryMessage(sendSummary)),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          },
        );
      },
    );
  }

  Future<void> _pickAndSendImage(BuildContext context, AppState state) async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;

    if (!context.mounted) return;

    final bytes = await file.readAsBytes();
    final base64String = base64Encode(bytes);
    final extension = file.name.split('.').last;

    final clip = ClipPayload(
      id: const Uuid().v4(),
      type: ClipType.image,
      createdAt: DateTime.now(),
      imageBase64: base64String,
      imageExtension: extension,
      contentHash: ContentHasher.imageHash(bytes),
      sourceDeviceName: state.identity.name,
    );

    final sendSummary = await state.sendClip(clip);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_sendSummaryMessage(sendSummary)),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}

class _MacHeader extends StatelessWidget {
  final TextEditingController searchController;
  final MobileClipFilter selectedFilter;
  final bool canClear;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<MobileClipFilter> onFilterChanged;
  final VoidCallback onDevicesPressed;
  final VoidCallback onClearPressed;

  const _MacHeader({
    required this.searchController,
    required this.selectedFilter,
    required this.canClear,
    required this.onSearchChanged,
    required this.onFilterChanged,
    required this.onDevicesPressed,
    required this.onClearPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        children: [
          Row(
            children: [
              const _ClipboardLogo(size: 48),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'ClipboardSS',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AppColors.text,
                  ),
                ),
              ),
              _HeaderIconButton(
                icon: Icons.devices_rounded,
                tooltip: 'Devices',
                onPressed: onDevicesPressed,
              ),
              const SizedBox(width: 10),
              _HeaderIconButton(
                icon: Icons.delete_sweep_rounded,
                tooltip: 'Delete all clips',
                onPressed: canClear ? onClearPressed : null,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.panel,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                TextField(
                  controller: searchController,
                  onChanged: onSearchChanged,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      color: AppColors.muted,
                    ),
                    prefixIconConstraints: BoxConstraints(
                      minWidth: 42,
                      minHeight: 40,
                    ),
                    hintText: 'Search clips',
                    hintStyle: TextStyle(
                      color: AppColors.muted,
                      fontWeight: FontWeight.w700,
                    ),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 11),
                  ),
                ),
                const SizedBox(height: 8),
                _FilterBar(
                  selectedFilter: selectedFilter,
                  onFilterChanged: onFilterChanged,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon),
      color: AppColors.text,
      disabledColor: AppColors.faint,
      style: IconButton.styleFrom(
        backgroundColor: AppColors.control,
        fixedSize: const Size(54, 42),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  final MobileClipFilter selectedFilter;
  final ValueChanged<MobileClipFilter> onFilterChanged;

  const _FilterBar({
    required this.selectedFilter,
    required this.onFilterChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _FilterButton(
          label: 'All',
          filter: MobileClipFilter.all,
          selectedFilter: selectedFilter,
          onFilterChanged: onFilterChanged,
        ),
        _FilterButton(
          label: 'Text',
          filter: MobileClipFilter.text,
          selectedFilter: selectedFilter,
          onFilterChanged: onFilterChanged,
        ),
        _FilterButton(
          label: 'Images',
          filter: MobileClipFilter.images,
          selectedFilter: selectedFilter,
          onFilterChanged: onFilterChanged,
        ),
        _FilterButton(
          label: 'Pinned',
          filter: MobileClipFilter.pinned,
          selectedFilter: selectedFilter,
          onFilterChanged: onFilterChanged,
        ),
      ],
    );
  }
}

class _FilterButton extends StatelessWidget {
  final String label;
  final MobileClipFilter filter;
  final MobileClipFilter selectedFilter;
  final ValueChanged<MobileClipFilter> onFilterChanged;

  const _FilterButton({
    required this.label,
    required this.filter,
    required this.selectedFilter,
    required this.onFilterChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = filter == selectedFilter;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: TextButton(
          onPressed: () => onFilterChanged(filter),
          style: TextButton.styleFrom(
            foregroundColor: AppColors.text,
            backgroundColor: isSelected ? AppColors.selected : null,
            padding: const EdgeInsets.symmetric(vertical: 11),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      ),
    );
  }
}

class _ClipboardLogo extends StatelessWidget {
  final double size;

  const _ClipboardLogo({required this.size});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.2),
      child: Image.asset(
        _logoAsset,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          return Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(size * 0.2),
            ),
            child: const Icon(
              Icons.assignment_turned_in_rounded,
              color: AppColors.accent,
            ),
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title.toUpperCase(),
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: AppColors.muted,
        fontWeight: FontWeight.w900,
        letterSpacing: 0,
      ),
    );
  }
}

class ReceivedClipTile extends StatelessWidget {
  final ClipPayload clip;
  final bool isProminent;
  final Future<void> Function(ClipPayload) onCopyImage;
  final VoidCallback onDelete;

  const ReceivedClipTile({
    super.key,
    required this.clip,
    this.isProminent = false,
    required this.onCopyImage,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final imageBytes = _imageBytes;

    return Card(
      color: isProminent ? AppColors.latest : AppColors.panel,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          if (imageBytes != null) {
            _showImagePreview(context, imageBytes);
          } else {
            _copy(context, imageBytes);
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _leading(imageBytes, context),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      clip.text ?? clip.previewText ?? 'Image Clip',
                      maxLines: isProminent ? 4 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: AppColors.text,
                        fontWeight: FontWeight.w800,
                        height: 1.18,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${clip.type == ClipType.text ? 'Text' : 'Image'} - ${_relativeTime(clip.createdAt)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.muted,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _ClipActions(
                clip: clip,
                imageBytes: imageBytes,
                onCopy: () => _copy(context, imageBytes),
                onDelete: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Uint8List? get _imageBytes {
    final base64 = clip.imageBase64;
    if (clip.type != ClipType.image || base64 == null || base64.isEmpty) {
      return null;
    }
    try {
      return base64Decode(base64);
    } on FormatException {
      return null;
    }
  }

  Widget _leading(Uint8List? imageBytes, BuildContext context) {
    if (imageBytes == null) {
      return Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: AppColors.control,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(
          Icons.format_align_left_rounded,
          color: AppColors.text,
        ),
      );
    }

    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(8)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          imageBytes,
          width: 56,
          height: 56,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => const SizedBox(
            width: 56,
            height: 56,
            child: Icon(Icons.broken_image_rounded, color: AppColors.muted),
          ),
        ),
      ),
    );
  }

  Future<void> _copy(BuildContext context, Uint8List? imageBytes) async {
    final messenger = ScaffoldMessenger.of(context);
    if (clip.text != null) {
      final syncService = desktopSyncService;
      if (syncService != null) {
        // Route through the sync service so the copy is not re-broadcast.
        await syncService.writeIncoming(clip);
      } else {
        await Clipboard.setData(ClipboardData(text: clip.text!));
      }
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Copied to clipboard'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (imageBytes != null) {
      await onCopyImage(clip);
      return;
    }

    messenger.showSnackBar(
      const SnackBar(
        content: Text('No clipboard data available'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showImagePreview(BuildContext context, Uint8List imageBytes) {
    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(16),
          child: Stack(
            alignment: Alignment.center,
            children: [
              InteractiveViewer(
                child: Image.memory(imageBytes, fit: BoxFit.contain),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  icon: const Icon(Icons.close_rounded),
                  color: Colors.white,
                  onPressed: () => Navigator.of(context).pop(),
                  style: IconButton.styleFrom(backgroundColor: Colors.black54),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ClipActions extends StatelessWidget {
  final ClipPayload clip;
  final Uint8List? imageBytes;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  const _ClipActions({
    required this.clip,
    required this.imageBytes,
    required this.onCopy,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 2,
      children: [
        _ClipActionButton(
          icon: Icons.keyboard_return_rounded,
          tooltip: 'Send to Mac',
          onPressed: () async {
            final state = context.read<AppState>();
            final sendSummary = await state.sendClip(clip);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(_sendSummaryMessage(sendSummary)),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          },
        ),
        _ClipActionButton(
          icon: Icons.copy_rounded,
          tooltip: imageBytes == null ? 'Copy text' : 'Copy image',
          onPressed: onCopy,
        ),
        _ClipActionButton(
          icon: Icons.delete_outline_rounded,
          tooltip: 'Delete clip',
          onPressed: onDelete,
        ),
      ],
    );
  }
}

class _ClipActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _ClipActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 22),
      color: AppColors.muted,
      onPressed: onPressed,
      tooltip: tooltip,
      splashRadius: 20,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
    );
  }
}

String _relativeTime(DateTime createdAt) {
  final difference = DateTime.now().difference(createdAt);
  if (difference.inSeconds < 60) return 'just now';
  if (difference.inMinutes < 60) {
    return '${difference.inMinutes} min. ago';
  }
  if (difference.inHours < 24) {
    final suffix = difference.inHours == 1 ? '' : 's';
    return '${difference.inHours} hr$suffix ago';
  }
  if (difference.inDays < 7) {
    final suffix = difference.inDays == 1 ? '' : 's';
    return '${difference.inDays} day$suffix ago';
  }
  return '${createdAt.month}/${createdAt.day}/${createdAt.year}';
}

String _sendSummaryMessage(ClipSendSummary summary) {
  if (!summary.hasVisiblePeers || !summary.hasPairedTargets) {
    return 'No paired devices nearby';
  }
  if (summary.successCount > 0 && summary.failureCount == 0) {
    final suffix = summary.successCount == 1 ? '' : 's';
    return 'Sent to ${summary.successCount} device$suffix';
  }
  if (summary.successCount > 0) {
    return 'Sent to ${summary.successCount}, ${summary.failureCount} unreachable';
  }
  return 'Mac not reachable';
}

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  final TextEditingController _codeController = TextEditingController();

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(title: const Text('Devices')),
      body: _devicesBody(context, state),
    );
  }

  Widget _devicesBody(BuildContext context, AppState state) {
    if (state.syncPermissionDenied) {
      return const Center(child: Text('Nearby device permission is required.'));
    }
    if (state.startupError != null) {
      return Center(child: Text('Sync could not start: ${state.startupError}'));
    }
    if (!state.isReady) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _PairingCodeCard(codeController: _codeController),
        const SizedBox(height: 16),
        _PairedDevicesCard(
          devices: state.pairedStore.devices,
          onUnpair: (id) async {
            await state.pairedStore.removeDevice(id);
            if (mounted) setState(() {});
          },
        ),
      ],
    );
  }
}

class _PairingCodeCard extends StatefulWidget {
  final TextEditingController codeController;

  const _PairingCodeCard({required this.codeController});

  @override
  State<_PairingCodeCard> createState() => _PairingCodeCardState();
}

class _PairingCodeCardState extends State<_PairingCodeCard> {
  @override
  void initState() {
    super.initState();
    widget.codeController.addListener(_update);
  }

  @override
  void didUpdateWidget(covariant _PairingCodeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.codeController != widget.codeController) {
      oldWidget.codeController.removeListener(_update);
      widget.codeController.addListener(_update);
    }
  }

  @override
  void dispose() {
    widget.codeController.removeListener(_update);
    super.dispose();
  }

  void _update() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final hostCode = state.hostCode;
    final canConnect =
        widget.codeController.text.length == 6 && !state.joinInProgress;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Pair a device',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            if (hostCode != null) ...[
              Text(
                'Show this code on the other device',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                hostCode,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 8,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: state.stopHosting,
                  child: const Text('Stop showing code'),
                ),
              ),
            ] else ...[
              FilledButton.icon(
                onPressed: state.startHosting,
                icon: const Icon(Icons.password_rounded, size: 18),
                label: const Text('Show pairing code'),
              ),
            ],
            const SizedBox(height: 20),
            TextField(
              controller: widget.codeController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              decoration: const InputDecoration(
                labelText: '6-digit code',
                counterText: '',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: canConnect
                  ? () => state.joinWithCode(widget.codeController.text)
                  : null,
              icon: state.joinInProgress
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.link_rounded, size: 18),
              label: const Text('Connect'),
            ),
            if (state.lastError != null) ...[
              const SizedBox(height: 12),
              Text(
                state.lastError!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PairedDevicesCard extends StatelessWidget {
  final List<PairedDevice> devices;
  final Future<void> Function(String id) onUnpair;

  const _PairedDevicesCard({required this.devices, required this.onUnpair});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Paired devices',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            if (devices.isEmpty)
              Text(
                'No paired devices',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF134E4A).withValues(alpha: 0.7),
                ),
              )
            else
              for (final device in devices) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: const BoxDecoration(
                          color: Color(0xFFE8F1F4),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.laptop_mac_rounded,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              device.name,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (device.host != null)
                              Text(
                                device.host!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: const Color(
                                    0xFF134E4A,
                                  ).withValues(alpha: 0.65),
                                ),
                              ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: () => onUnpair(device.id),
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                        ),
                        child: const Text('Unpair'),
                      ),
                    ],
                  ),
                ),
                if (device != devices.last) const Divider(height: 1),
              ],
          ],
        ),
      ),
    );
  }
}

class ClipboardSendSheet extends StatefulWidget {
  final String initialText;
  final ValueChanged<String> onSend;

  const ClipboardSendSheet({
    super.key,
    required this.initialText,
    required this.onSend,
  });

  @override
  State<ClipboardSendSheet> createState() => _ClipboardSendSheetState();
}

class _ClipboardSendSheetState extends State<ClipboardSendSheet> {
  late final TextEditingController _controller;
  bool _isEmpty = true;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _isEmpty = widget.initialText.trim().isEmpty;
    _controller.addListener(_updateEmptyState);
  }

  void _updateEmptyState() {
    final empty = _controller.text.trim().isEmpty;
    if (empty != _isEmpty) {
      setState(() {
        _isEmpty = empty;
      });
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_updateEmptyState);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Review Clipboard Content',
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF134E4A),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFF0FDFA),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF99F6E4)),
                ),
                child: TextField(
                  controller: _controller,
                  maxLines: 8,
                  minLines: 3,
                  autofocus: true,
                  decoration: const InputDecoration(
                    contentPadding: EdgeInsets.all(16),
                    border: InputBorder.none,
                    hintText: 'Type or paste clipboard content here...',
                    hintStyle: TextStyle(color: Colors.grey),
                  ),
                  style: textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF134E4A),
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _isEmpty
                        ? null
                        : () {
                            widget.onSend(_controller.text);
                            Navigator.pop(context);
                          },
                    icon: const Icon(Icons.send_rounded, size: 16),
                    label: const Text('Send'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
