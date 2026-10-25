import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import 'widgets/scan_sweep.dart';

/// Camera barcode scanner. Pops with the barcode string (EAN/UPC), or null.
/// Always offers manual entry (e.g. when camera permission is denied).
class BarcodeScanScreen extends StatefulWidget {
  const BarcodeScanScreen({super.key});

  @override
  State<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends State<BarcodeScanScreen> {
  final _controller = MobileScannerController(
    formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
    ],
  );
  bool _done = false;
  bool _torch = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final v = b.rawValue?.trim();
      if (v != null && RegExp(r'^\d{6,14}$').hasMatch(v)) {
        _done = true;
        Haptics.success();
        Navigator.of(context).pop(v);
        return;
      }
    }
  }

  Future<void> _manual() async {
    final code = await showHudBottomSheet<String>(
      context,
      title: 'Enter barcode',
      builder: (_) => const _ManualEntry(),
    );
    if (code != null && mounted) Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              errorBuilder: (context, error) =>
                  _ScannerError(error: error, onManual: _manual),
            ),
          ),
          Positioned.fill(
            child: BarcodeScanOverlay(
              torchOn: _torch,
              onTorch: () {
                Haptics.selection();
                setState(() => _torch = !_torch);
                _controller.toggleTorch();
              },
              onManual: _manual,
              onClose: () => Navigator.of(context).maybePop(),
            ),
          ),
        ],
      ),
    );
  }
}

/// The HUD chrome over the camera: dimmed surround, bracketed scan window
/// with a sweeping line, a frosted top bar and an instruction panel.
class BarcodeScanOverlay extends StatelessWidget {
  const BarcodeScanOverlay({
    super.key,
    required this.torchOn,
    required this.onTorch,
    required this.onManual,
    required this.onClose,
  });

  final bool torchOn;
  final VoidCallback onTorch;
  final VoidCallback onManual;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final mq = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final w = (box.maxWidth - 64).clamp(220.0, 340.0);
        const h = 170.0;
        final window = Rect.fromCenter(
          center: Offset(box.maxWidth / 2, box.maxHeight * 0.42),
          width: w,
          height: h,
        );
        return Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(painter: _CutoutPainter(window: window)),
              ),
            ),
            Positioned.fromRect(
              rect: window,
              child: const HudFrame(
                color: AppColors.cyan,
                cornerLength: 26,
                strokeWidth: 3,
                inset: -4,
                tag: 'EAN · UPC',
                child: ClipRRect(
                  borderRadius: BorderRadius.all(Radius.circular(AppRadii.md)),
                  child: ScanSweep(color: AppColors.cyan),
                ),
              ),
            ),
            // Top bar.
            Positioned(
              left: AppSpacing.md,
              right: AppSpacing.md,
              top: mq.padding.top + AppSpacing.sm,
              child: Row(
                children: [
                  _RoundGlass(
                    icon: Icons.close_rounded,
                    label: 'Close scanner',
                    onTap: onClose,
                  ),
                  Expanded(
                    child: Text(
                      'Scan barcode',
                      textAlign: TextAlign.center,
                      style: t.titleMedium?.copyWith(color: Colors.white),
                    ),
                  ),
                  _RoundGlass(
                    icon: torchOn
                        ? Icons.flashlight_on_rounded
                        : Icons.flashlight_off_outlined,
                    label: torchOn ? 'Turn torch off' : 'Turn torch on',
                    active: torchOn,
                    onTap: onTorch,
                  ),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: window.bottom + AppSpacing.lg,
              child: Text(
                'ALIGN THE BARCODE INSIDE THE FRAME',
                textAlign: TextAlign.center,
                style: hud.mono(size: 11, color: Colors.white70),
              ),
            ),
            Positioned(
              left: AppSpacing.gutter,
              right: AppSpacing.gutter,
              bottom: mq.padding.bottom + AppSpacing.xl,
              child: GlassPanel(
                blur: 16,
                fill: const LinearGradient(
                  colors: [Color(0xCC0A111D), Color(0xCC0A111D)],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Packaged foods are looked up on Open Food Facts. '
                      'Scanned label data is marked as verified.',
                      style: t.bodySmall?.copyWith(color: Colors.white70),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    HudButton.secondary(
                      label: 'Type barcode instead',
                      icon: Icons.keyboard_alt_outlined,
                      expand: true,
                      onPressed: onManual,
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _RoundGlass extends StatelessWidget {
  const _RoundGlass({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: PressableScale(
        onTap: onTap,
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active
                ? AppColors.gold.withValues(alpha: 0.25)
                : Colors.black.withValues(alpha: 0.45),
            border: Border.all(
              color: (active ? AppColors.gold : Colors.white).withValues(
                alpha: 0.5,
              ),
            ),
          ),
          child: Icon(
            icon,
            color: active ? AppColors.gold : Colors.white,
            size: 22,
          ),
        ),
      ),
    );
  }
}

class _CutoutPainter extends CustomPainter {
  _CutoutPainter({required this.window});
  final Rect window;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(
        RRect.fromRectAndRadius(window, const Radius.circular(AppRadii.md)),
      );
    canvas.drawPath(path, Paint()..color = const Color(0xA604060B));
  }

  @override
  bool shouldRepaint(_CutoutPainter old) => old.window != window;
}

class _ManualEntry extends StatefulWidget {
  const _ManualEntry();

  @override
  State<_ManualEntry> createState() => _ManualEntryState();
}

class _ManualEntryState extends State<_ManualEntry> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  bool get _valid => RegExp(r'^\d{6,14}$').hasMatch(_ctrl.text.trim());

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          style: hud.number(size: 30),
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(hintText: '8901058851427'),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) {
            if (_valid) Navigator.pop(context, _ctrl.text.trim());
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          '6–14 DIGITS · EAN / UPC',
          textAlign: TextAlign.center,
          style: hud.mono(size: 10.5),
        ),
        const SizedBox(height: AppSpacing.lg),
        HudButton(
          label: 'Look up',
          icon: Icons.travel_explore_rounded,
          expand: true,
          onPressed: _valid
              ? () => Navigator.pop(context, _ctrl.text.trim())
              : null,
        ),
      ],
    );
  }
}

class _ScannerError extends StatelessWidget {
  const _ScannerError({required this.error, required this.onManual});
  final MobileScannerException error;
  final VoidCallback onManual;

  @override
  Widget build(BuildContext context) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: EmptyState(
            icon: denied
                ? Icons.no_photography_outlined
                : Icons.videocam_off_outlined,
            color: AppColors.warning,
            eyebrow: denied ? 'CAMERA BLOCKED' : 'CAMERA OFFLINE',
            title: denied ? 'Camera permission denied' : 'Camera unavailable',
            message: denied
                ? 'Allow camera access for Athlete OS in Android settings '
                      'to scan barcodes, or type the number instead.'
                : 'The camera could not start. You can type the barcode '
                      'number instead.',
            actionLabel: 'Enter barcode manually',
            onAction: onManual,
          ),
        ),
      ),
    );
  }
}
