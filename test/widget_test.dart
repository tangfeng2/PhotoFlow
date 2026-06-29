import 'package:flutter_test/flutter_test.dart';
import 'package:photos_app/main.dart';

void main() {
  testWidgets('Photos app renders shell', (tester) async {
    await tester.pumpWidget(const PhotosApp());
    await tester.pump();

    expect(find.text('Photos'), findsOneWidget);
    expect(find.text('Scan'), findsOneWidget);
  });
}
