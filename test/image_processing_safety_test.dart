import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/image.dart' as pixels;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'script reassembly survives repeated native decode, encode and runtime disposal',
    () async {
      final bytes = Uint32List.fromList([
        0xff0000ff,
        0xff00ff00,
        0xffff0000,
        0xffffffff,
      ]);
      final image = pixels.Image(Uint32List.sublistView(bytes, 1, 3), 1, 2);
      var encoded = image.encodePng();
      for (var i = 0; i < 3; i++) {
        encoded = await pixels.modifyImageWithScript(
          encoded,
          'function modifyImage(image) { const output = Image.empty(image.width, image.height); output.fillImageRangeAt(0, 0, image, 0, 1, 1, 1); output.fillImageRangeAt(0, 1, image, 0, 0, 1, 1); return output; }',
        );
      }
      final decoded = await pixels.Image.decodeImage(encoded);
      expect(decoded.getPixel(0, 0).value, 0xffff0000);
      expect(decoded.getPixel(0, 1).value, 0xff00ff00);
    },
  );
  test('RGBA color construction agrees with its channels and pixel access', () {
    final color = pixels.Color(17, 43, 211, 123);
    expect([color.r, color.g, color.b, color.a], [17, 43, 211, 123]);
    final image = pixels.Image.empty(2, 2);
    image.setPixel(1, 1, color);
    expect(image.getPixel(1, 1).value, color.value);
  });

  test(
    'strip reassembly preserves every pixel including uneven final strips',
    () {
      final source = pixels.Image(
        Uint32List.fromList(List.generate(21, (i) => 0xff000000 | i)),
        3,
        7,
      );
      final result = pixels.Image.empty(3, 7);
      result.fillImageRangeAt(0, 0, source, 0, 5, 3, 2);
      result.fillImageRangeAt(0, 2, source, 0, 2, 3, 3);
      result.fillImageRangeAt(0, 5, source, 0, 0, 3, 2);
      expect(List.generate(7, (y) => result.getPixel(0, y).r), [
        15,
        18,
        6,
        9,
        12,
        0,
        3,
      ]);
      expect(() => source.copyRange(-1, 0, 1, 1), throwsArgumentError);
      expect(
        () => result.fillImageRangeAt(0, 0, source, 0, -1, 1, 1),
        throwsArgumentError,
      );
      expect(() => result.fillImageAt(-1, 0, source), throwsArgumentError);
    },
  );
}
