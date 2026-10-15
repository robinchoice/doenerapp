import 'package:doener_models/doener_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../core/app_data.dart';
import '../../core/session.dart';
import '../../ui/widgets.dart';
import '../social/invite.dart';

/// Logs in with a magic-link token (web: `/login?token=…`).
Future<void> completeLinkLogin(BuildContext context, String token, {String? inviteCode}) async {
  final session = context.read<Session>();
  final data = context.read<AppData>();
  try {
    final response = await session.verify(VerifyRequest(token: token, inviteCode: inviteCode));
    await data.onSignedIn(response.user.id);
    if (context.mounted) showMessage(context, 'Angemeldet als ${response.user.displayName}');
  } catch (e) {
    if (context.mounted) showMessage(context, e.toString());
  }
}

/// Without an account there is nothing to do in the app — this screen stands
/// in front of everything until the user is logged in.
class LoginScreen extends StatefulWidget {
  /// Code of the invite link that brought the user here, if any.
  final String? inviteCode;
  const LoginScreen({super.key, this.inviteCode});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;
  String? _error;

  /// The address has no account and sign-up is closed: the way in is the tester request.
  bool _signupClosed = false;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
      _signupClosed = false;
    });
    try {
      await action();
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _signupClosed = e.status == 403;
        });
      }
    } on OfflineException catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendCode() => _run(() async {
        if (!Validation.isValidEmail(_email.text)) throw const ApiException(400, 'Bitte gib eine gültige E-Mail ein.');
        await context.read<Session>().requestCode(Validation.normalizeEmail(_email.text), inviteCode: widget.inviteCode);
        setState(() => _codeSent = true);
      });

  // Once the session is set, the app moves on by itself — this screen disappears.
  Future<void> _verify() => _run(() async {
        final session = context.read<Session>();
        final data = context.read<AppData>();
        final response = await session.verify(VerifyRequest(
          email: Validation.normalizeEmail(_email.text),
          code: _code.text.trim(),
          inviteCode: widget.inviteCode,
        ));
        await data.onSignedIn(response.user.id);
      });

  /// The form on the landing page; with an invite code, the request tells whose link it was.
  Future<void> _applyAsTester() async {
    final page = Uri.parse(context.read<Session>().apiBase).resolve('/');
    final code = widget.inviteCode;
    final uri = page.replace(queryParameters: code == null ? null : {'von': code}, fragment: 'test');
    // In the browser the landing page takes this tab, the apps open the browser.
    await launchUrl(uri, mode: kIsWeb ? LaunchMode.platformDefault : LaunchMode.externalApplication, webOnlyWindowName: '_self');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final expired = context.watch<Session>().expired;
    return Scaffold(
      bottomNavigationBar: const SafeArea(top: false, child: PleasanceFooter()),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                const Center(child: BrandTile(size: 72)),
                const SizedBox(height: 20),
                if (widget.inviteCode != null) ...[
                  InviterBanner(code: widget.inviteCode!),
                  const SizedBox(height: 16),
                ],
                Text('Anmelden', style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(
                  _codeSent
                      ? 'Wir haben dir einen 6-stelligen Code geschickt. Du kannst auch einfach auf den Link in der Mail tippen.'
                      : expired
                          ? 'Deine Sitzung ist abgelaufen. Ungesendete Einträge bleiben gespeichert, bis du dich wieder anmeldest.'
                          : 'Kein Passwort nötig – wir schicken dir einen Code per Mail. Damit sehen deine Freunde, wo du Döner isst.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _email,
                  enabled: !_codeSent && !_busy,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'E-Mail', prefixIcon: Icon(Icons.mail_outline)),
                  onSubmitted: (_) => _sendCode(),
                ),
                if (_codeSent) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _code,
                    enabled: !_busy,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    maxLength: 6,
                    decoration: const InputDecoration(labelText: 'Code', prefixIcon: Icon(Icons.pin_outlined)),
                    onSubmitted: (_) => _verify(),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: TextStyle(color: theme.colorScheme.error), textAlign: TextAlign.center),
                ],
                if (_signupClosed) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _applyAsTester,
                    icon: const Icon(Icons.science_outlined),
                    label: const Text('Als Tester bewerben'),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : (_codeSent ? _verify : _sendCode),
                  child: _busy
                      ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_codeSent ? 'Anmelden' : 'Code schicken'),
                ),
                if (_codeSent)
                  TextButton(
                    onPressed: _busy ? null : () => setState(() => _codeSent = false),
                    child: const Text('Andere E-Mail / neuen Code'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Stands in front of the app while the account still has its generated name —
/// friends should see who checked in, not "Döner-Fan-4821".
class ChooseNameScreen extends StatefulWidget {
  const ChooseNameScreen({super.key});

  @override
  State<ChooseNameScreen> createState() => _ChooseNameScreenState();
}

class _ChooseNameScreenState extends State<ChooseNameScreen> {
  final _name = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final error = Validation.displayNameError(_name.text);
    if (error != null) return setState(() => _error = error);
    setState(() => _busy = true);
    try {
      await context.read<Session>().updateDisplayName(_name.text.trim());
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Wie heißt du?')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text('Unter diesem Namen sehen dich deine Freunde, wenn du eincheckst.'),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              autofocus: true,
              maxLength: Validation.displayNameMax,
              decoration: InputDecoration(labelText: 'Anzeigename', errorText: _error),
              onSubmitted: (_) => _save(),
            ),
            FilledButton(onPressed: _busy ? null : _save, child: const Text('Weiter')),
          ],
        ),
      );
}
