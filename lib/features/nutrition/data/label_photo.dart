import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

/// Backend image limit (decoded bytes), mirrors `AiImage.maxBytes`.
const labelPhotoMaxBytes = 1024 * 1024;

/// A label photo ready to send: JPEG, at most [labelPhotoMaxBytes].
class LabelPhoto {
  const LabelPhoto(this.bytes, {this.mimeType = 'image/jpeg'});
  final Uint8List bytes;
  final String mimeType;
}

/// Thrown when a photo can't be decoded or squeezed under 1 MB.
class LabelPhotoException implements Exception {
  const LabelPhotoException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Downscales (longest side ≤ 1600 px, enough for small label print) and
/// re-encodes as JPEG, stepping quality/size down until it fits [maxBytes].
/// Pure Dart; run it off the UI thread with [compute].
Uint8List compressLabelPhoto(
  Uint8List bytes, {
  int maxBytes = labelPhotoMaxBytes,
}) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const LabelPhotoException(
      'That file is not a photo the app can read. Use a JPEG or PNG.',
    );
  }
  final oriented = img.bakeOrientation(decoded);
  for (final (side, quality) in const [
    (1600, 85),
    (1600, 72),
    (1280, 72),
    (1024, 65),
    (800, 60),
  ]) {
    final longest = oriented.width > oriented.height
        ? oriented.width
        : oriented.height;
    final scaled = longest <= side
        ? oriented
        : oriented.width >= oriented.height
        ? img.copyResize(oriented, width: side)
        : img.copyResize(oriented, height: side);
    final out = img.encodeJpg(scaled, quality: quality);
    if (out.length <= maxBytes) return out;
  }
  throw const LabelPhotoException(
    'The photo is still over 1 MB after compression. Retake it closer to '
    'the label. No photo was sent.',
  );
}

/// Picks a label photo (camera or gallery) and returns it compressed.
/// Returns null when the user cancels. Overridden in tests.
typedef LabelPhotoPicker = Future<LabelPhoto?> Function(ImageSource source);

final labelPhotoPickerProvider = Provider<LabelPhotoPicker>(
  (ref) => (source) async {
    final file = await ImagePicker().pickImage(
      source: source,
      // Pre-shrink on the platform side; the exact 1 MB cap is enforced below.
      maxWidth: 2000,
      maxHeight: 2000,
      imageQuality: 90,
    );
    if (file == null) return null;
    final raw = await file.readAsBytes();
    final jpeg = await compute(compressLabelPhoto, raw);
    return LabelPhoto(jpeg);
  },
);
