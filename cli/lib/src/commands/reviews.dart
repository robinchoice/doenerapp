import 'package:doener_models/doener_models.dart';

import '../client.dart';
import '../command.dart';

String _score(double? score) => score == null ? 'ohne Wertung' : decimal(score);

String _line(ReviewDto review) =>
    [
      '${day(review.updatedAt)} ${review.placeName} – ${_score(review.headline(Diet.all))}',
      if (review.price case final price?) euros(price),
      if (review.text case final text?) '„$text“',
    ].join(' · ') +
    reactionText(review.reactions);

/// `sauce=4,5` → (sauce, 4.5); the server checks the range.
(RatingItem, double) _rating(String value) {
  final (name, number) = switch (value.split('=')) {
    [final name, final number] => (name, number),
    _ => ('', ''),
  };
  final item = RatingItem.values.asNameMap()[name.trim()];
  final rating = double.tryParse(number.trim().replaceAll(',', '.'));
  if (item == null || rating == null) throw Failure('--rate <punkt>=<1–5> erwartet, nicht „$value“.', Exit.usage);
  return (item, rating);
}

final reviews = <String, Command>{
  'reviews': Command(
    help: [('reviews', 'Die eigenen Bewertungen, die neueste zuerst')],
    run: (ctx) async {
      requireLogin(ctx);
      final reviews = parseList(await ctx.api.get('/me/reviews'), ReviewDto.fromJson);
      return (
        data: {'reviews': [for (final review in reviews) review.toJson()]},
        text: reviews.isEmpty ? 'Noch keine Bewertungen.' : reviews.map(_line).join('\n'),
      );
    },
  ),
  // One review per user and place, and PUT replaces it: what the call
  // doesn't name, such as the expert details from the app, stays as it was.
  'review': Command(
    help: [
      ('review --place <placeId> --rate <punkt>=<1–5> …', 'Laden bewerten, ändert nur die genannten Angaben'),
      ('  [--price <euro>] [--text <text>]', 'Preis des Döners, Text'),
      ('  Punkte:', RatingItem.values.map((item) => item.name).join(', ')),
    ],
    options: (parser) => parser
      ..addOption('place')
      ..addMultiOption('rate', splitCommas: false)
      ..addOption('price')
      ..addOption('text'),
    run: (ctx) async {
      requireLogin(ctx);
      final placeId = ctx.args.option('place') ?? (throw const Failure('--place <placeId> fehlt.', Exit.usage));
      final ratings = {for (final (item, rating) in ctx.args.multiOption('rate').map(_rating)) item: rating};
      final path = '/places/${Uri.encodeComponent(placeId)}';
      // Loads a shop the server doesn't know yet, as opening it in the app does
      await ctx.api.get(path);
      final previous = parseList(await ctx.api.get('/me/reviews'), ReviewDto.fromJson).where((r) => r.placeId == placeId).firstOrNull;
      final request = UpsertReviewRequest(
        ratings: {...?previous?.ratings, ...ratings},
        veganOptions: previous?.veganOptions,
        ayranHomemade: previous?.ayranHomemade,
        price: centsOption(ctx, 'price') ?? previous?.price,
        ingredients: previous?.ingredients,
        meat: previous?.meat,
        skewer: previous?.skewer,
        bread: previous?.bread,
        text: ctx.args.option('text') ?? previous?.text,
      );
      final review = parse(await ctx.api.put('$path/review', request.toJson()), ReviewDto.fromJson);
      return (data: {'review': review.toJson()}, text: 'Bewertung gespeichert: ${_line(review)}');
    },
  ),
};
