import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:provider/provider.dart';

import '../../core/session.dart';
import '../../ui/widgets.dart';

/// "Laden fehlt?" — reports go to the server (they used to stay on the device).
class ReportShopSheet extends StatefulWidget {
  final LatLng? position;
  const ReportShopSheet({super.key, this.position});

  @override
  State<ReportShopSheet> createState() => _ReportShopSheetState();
}

class _ReportShopSheetState extends State<ReportShopSheet> {
  final _name = TextEditingController();
  final _hint = TextEditingController();
  final _note = TextEditingController();
  bool _attachLocation = true;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _hint.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _busy = true);
    final position = _attachLocation ? widget.position : null;
    try {
      await context.read<Session>().api.post(
        '/shop-reports',
        ShopReportRequest(
          name: _name.text.trim(),
          hint: Validation.clean(_hint.text),
          latitude: position?.latitude,
          longitude: position?.longitude,
          note: Validation.clean(_note.text),
        ).toJson(),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      showMessage(context, 'Danke! Wir schauen uns den Laden an.');
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      children: [
        Text('Laden fehlt?', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Name (z. B. Erbil)'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _hint,
          decoration: const InputDecoration(labelText: 'Adresse oder Stadtteil (optional)'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _note,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(labelText: 'Was ist besonders? (optional)'),
        ),
        if (widget.position != null)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Kartenmitte als Standort anhängen'),
            value: _attachLocation,
            onChanged: (v) => setState(() => _attachLocation = v),
          ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _busy || _name.text.trim().length < Validation.shopNameMin ? null : _send,
          child: const Text('Senden'),
        ),
      ],
    );
  }
}
