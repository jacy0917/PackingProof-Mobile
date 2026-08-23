import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/app/app_build_config.dart';
import 'package:packing_proof_mobile/app/packing_proof_mobile_app.dart';
import 'package:packing_proof_mobile/app/packing_proof_theme.dart';

void main() {
  test('浅色与深色主题提供对应亮度和可区分的表面色', () {
    final ThemeData light = PackingProofTheme.light();
    final ThemeData dark = PackingProofTheme.dark();

    expect(light.brightness, Brightness.light);
    expect(dark.brightness, Brightness.dark);
    expect(PackingProofMobileApp.themeMode, ThemeMode.system);
    expect(light.colorScheme.surface, isNot(dark.colorScheme.surface));
    expect(
      light.extension<PackingProofSemanticColors>()?.dangerAction,
      dark.extension<PackingProofSemanticColors>()?.dangerAction,
    );
    expect(
      dark.colorScheme.surfaceContainer.computeLuminance(),
      lessThan(light.colorScheme.surfaceContainer.computeLuminance()),
    );
  });

  testWidgets('应用跟随系统深色模式并使用深色卡片', (WidgetTester tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(
      MaterialApp(
        theme: PackingProofTheme.light(),
        darkTheme: PackingProofTheme.dark(),
        themeMode: PackingProofMobileApp.themeMode,
        home: StartupNoticeScreen(
          buildConfig: const AppBuildConfig(),
          onConfirm: () async {},
        ),
      ),
    );

    final BuildContext context = tester.element(
      find.byKey(const Key('startup-notice-card')),
    );
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Container card = tester.widget<Container>(
      find.byKey(const Key('startup-notice-card')),
    );
    final BoxDecoration decoration = card.decoration! as BoxDecoration;

    expect(Theme.of(context).brightness, Brightness.dark);
    expect(decoration.color, colors.surfaceContainer);
    expect(decoration.border!.top.color, colors.outlineVariant);
  });
}
