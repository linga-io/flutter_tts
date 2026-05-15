import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_tts_example/main.dart';

void main() {
  testWidgets('renders the TTS example app', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.text('Flutter TTS'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('PLAY'), findsOneWidget);
    expect(find.text('STOP'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
  });
}
