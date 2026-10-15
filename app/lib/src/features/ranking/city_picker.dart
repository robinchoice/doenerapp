import 'package:doener_models/doener_models.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_data.dart';
import '../../core/location.dart';
import '../../ui/widgets.dart';

/// Lets the user look around in another city: Start and Ranking then show
/// its places, reviews and trends. Check-ins stay where the user is.
Future<void> showCityPicker(BuildContext context) => showAppSheet(context, (_) => const _CityPicker());

class _CityPicker extends StatefulWidget {
  const _CityPicker();

  @override
  State<_CityPicker> createState() => _CityPickerState();
}

class _CityPickerState extends State<_CityPicker> {
  late final Future<List<CityDto>> _cities = context.read<AppData>().cities();

  void _pick(CityDto? city) {
    context.read<LocationService>().visit(city);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visiting = context.watch<LocationService>().visiting;
    return SafeArea(
      child: FutureBuilder<List<CityDto>>(
        future: _cities,
        builder: (context, snapshot) => ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Text('Döner-Tourismus 🧳', style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(
              'Schau, wo man anderswo am besten isst. Einchecken geht weiter nur vor Ort.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.near_me),
              title: const Text('Meine Gegend'),
              trailing: visiting == null ? Icon(Icons.check, color: context.accent) : null,
              onTap: () => _pick(null),
            ),
            if (snapshot.connectionState != ConnectionState.done)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
            else if (snapshot.hasError)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Städte nicht geladen: ${snapshot.error}', textAlign: TextAlign.center),
              )
            else
              for (final city in snapshot.data!)
                ListTile(
                  leading: const Icon(Icons.location_city),
                  title: Text(city.name),
                  subtitle: Text(city.ratedPlaces == 1 ? '1 Laden bewertet' : '${city.ratedPlaces} Läden bewertet'),
                  trailing: visiting?.name == city.name ? Icon(Icons.check, color: context.accent) : null,
                  onTap: () => _pick(city),
                ),
          ],
        ),
      ),
    );
  }
}

/// The button that opens [showCityPicker], named after the shown city.
class CityButton extends StatelessWidget {
  final String label;
  const CityButton({super.key, required this.label});

  @override
  Widget build(BuildContext context) => ActionChip(
        avatar: const Icon(Icons.travel_explore, size: 18),
        label: Text(label),
        tooltip: 'Andere Stadt ansehen',
        onPressed: () => showCityPicker(context),
      );
}
