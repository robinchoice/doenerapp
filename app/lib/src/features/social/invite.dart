import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../ui/widgets.dart';
import 'friends.dart';

/// Opens the system share sheet with the invite link. [context] should belong
/// to the tapped button — on iPad the sheet is anchored to it.
Future<void> shareInvite(BuildContext context, InviteDto invite) async {
  final box = context.findRenderObject() as RenderBox?;
  await SharePlus.instance.share(ShareParams(
    text: 'Komm in meine Döner-Crew! In der Döner App siehst du, wo ich gerade Döner esse: ${invite.url}',
    sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
  ));
}

/// The personal invite link as QR code, with a share button.
class InvitePanel extends StatefulWidget {
  final bool allowReset;
  const InvitePanel({super.key, this.allowReset = false});

  @override
  State<InvitePanel> createState() => _InvitePanelState();
}

class _InvitePanelState extends State<InvitePanel> {
  late Future<InviteDto> _invite = context.read<Friends>().fetchInvite();

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Link zurücksetzen?'),
        content: const Text('Der alte Link und QR-Code funktionieren danach nicht mehr. Wer schon befreundet ist, bleibt es.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Abbrechen')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Zurücksetzen')),
        ],
      ),
    );
    if (ok == true && mounted) setState(() => _invite = context.read<Friends>().resetInvite());
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<InviteDto>(
        future: _invite,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Link nicht geladen: ${snapshot.error}', textAlign: TextAlign.center),
                TextButton(
                  onPressed: () => setState(() => _invite = context.read<Friends>().fetchInvite()),
                  child: const Text('Erneut versuchen'),
                ),
              ],
            );
          }
          final invite = snapshot.data;
          if (invite == null) return const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Dark on white in dark mode too — cameras need the contrast.
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                child: QrImageView(data: invite.url, size: 200),
              ),
              const SizedBox(height: 8),
              SelectableText(invite.url, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 16),
              Builder(
                builder: (buttonContext) => FilledButton.icon(
                  onPressed: () => shareInvite(buttonContext, invite),
                  icon: const Icon(Icons.share),
                  label: const Text('Link teilen'),
                ),
              ),
              if (widget.allowReset) TextButton(onPressed: _reset, child: const Text('Link zurücksetzen')),
            ],
          );
        },
      );
}

class InviteSheet extends StatelessWidget {
  const InviteSheet({super.key});

  @override
  Widget build(BuildContext context) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Text('Freunde einladen', style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          const Text(
            'Teil deinen Link oder lass den QR-Code scannen. Wer ihn öffnet und sich anmeldet, ist sofort mit dir befreundet.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          const InvitePanel(allowReset: true),
        ],
      );
}

/// Last onboarding step — the app only gets good with friends.
class InviteStepScreen extends StatelessWidget {
  final VoidCallback onDone;
  const InviteStepScreen({super.key, required this.onDone});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                Text(
                  'Hol deine Döner-Crew dazu',
                  style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Wer deinen Link öffnet und sich anmeldet, ist sofort mit dir befreundet. Dann seht ihr, wer gerade wo Döner isst.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
                ),
                const SizedBox(height: 24),
                const InvitePanel(),
                const SizedBox(height: 8),
                TextButton(onPressed: onDone, child: const Text('Weiter')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown on welcome and login when the user came through someone's invite link.
class InviterBanner extends StatefulWidget {
  final String code;
  const InviterBanner({super.key, required this.code});

  @override
  State<InviterBanner> createState() => _InviterBannerState();
}

class _InviterBannerState extends State<InviterBanner> {
  late Future<UserDto> _inviter = context.read<Friends>().inviter(widget.code);

  @override
  void didUpdateWidget(InviterBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Another invite link was opened in the meantime.
    if (widget.code != oldWidget.code) _inviter = context.read<Friends>().inviter(widget.code);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<UserDto>(
        future: _inviter,
        builder: (context, snapshot) {
          final inviter = snapshot.data;
          if (inviter == null) return const SizedBox.shrink();
          return GlassCard(
            child: Row(
              children: [
                const Text('🥙', style: TextStyle(fontSize: 28)),
                const SizedBox(width: 12),
                Expanded(child: Text('${inviter.displayName} hat dich eingeladen. Nach der Anmeldung seid ihr befreundet.')),
              ],
            ),
          );
        },
      );
}
