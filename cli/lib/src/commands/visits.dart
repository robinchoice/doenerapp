import 'package:doener_models/doener_models.dart';
import 'package:uuid/uuid.dart';

import '../client.dart';
import '../command.dart';

String _food(String? id) => switch (FoodItem.byId(id)) {
  final food? => ' · ${food.emoji} ${food.label}',
  null => '',
};

String _line(VisitDto visit) => '${day(visit.visitedAt)} ${visit.placeName}${_food(visit.foodType)}${reactionText(visit.reactions)}';

final visits = <String, Command>{
  'visits': Command(
    help: [('visits', 'Die eigenen Check-ins, der neueste zuerst')],
    run: (ctx) async {
      requireLogin(ctx);
      final visits = parseList(await ctx.api.get('/me/visits'), VisitDto.fromJson);
      return (
        data: {'visits': [for (final visit in visits) visit.toJson()]},
        text: visits.isEmpty ? 'Noch keine Check-ins.' : visits.map(_line).join('\n'),
      );
    },
  ),
  'checkin': Command(
    help: [
      ('checkin --place <placeId>', 'Jetzt im Laden einchecken, Freunde sehen es live'),
      ('  [--food <essen>]', 'Was es gibt: ${FoodItem.all.map((food) => food.id).join(', ')}'),
    ],
    options: (parser) => parser
      ..addOption('place')
      ..addOption('food', allowed: [for (final food in FoodItem.all) food.id]),
    run: (ctx) async {
      requireLogin(ctx);
      final placeId = ctx.args.option('place') ?? (throw const Failure('--place <placeId> fehlt.', Exit.usage));
      final path = '/places/${Uri.encodeComponent(placeId)}';
      // Loads a shop the server doesn't know yet, as opening it in the app does
      await ctx.api.get(path);
      final request = CreateVisitRequest(id: const Uuid().v4(), visitedAt: DateTime.now().toUtc(), foodType: ctx.args.option('food'));
      final visit = parse(await ctx.api.post('$path/visits', request.toJson()), VisitDto.fromJson);
      return (data: {'visit': visit.toJson()}, text: 'Eingecheckt: ${_line(visit)}');
    },
  ),
};
