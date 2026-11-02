import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../ui/widgets.dart';

const _playUrl = 'https://play.google.com/store/apps/details?id=com.robinchoice.doener';

/// Replaces the app once the API no longer serves this build. [url] comes
/// from the API: TestFlight on iOS, the APK on Android, '' without a link.
class UpdateScreen extends StatelessWidget {
  final String url;
  const UpdateScreen({super.key, required this.url});

  Future<void> _open() async {
    var target = url;
    // Installs from Play get their updates there.
    if (defaultTargetPlatform == TargetPlatform.android && (await PackageInfo.fromPlatform()).installerStore == 'com.android.vending') {
      target = _playUrl;
    }
    await launchUrl(Uri.parse(target), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: EmptyState(
            icon: Icons.system_update,
            title: 'Update nötig',
            message: 'Diese Version der Döner App ist zu alt. Aktualisiere sie, deine Daten bleiben.',
            action: url.isEmpty ? null : FilledButton(onPressed: _open, child: const Text('Jetzt aktualisieren')),
          ),
        ),
      );
}
