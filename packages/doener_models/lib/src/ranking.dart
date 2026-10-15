/// How many reviews of the area's average every place starts with.
const rankingPriorWeight = 3;

/// Weighted average for the ranking: places with few reviews are pulled
/// towards [mean] (the average of all reviews in the area), so a single 5
/// doesn't beat many 4.5s.
double weightedRating(double average, int count, double mean) =>
    (average * count + mean * rankingPriorWeight) / (count + rankingPriorWeight);

/// The best-of list of a city ("Bestenliste"): reviews of one calendar year
/// (Europe/Berlin), places with at least [bestOfMinReviews] of them, in the
/// order of [weightedRating]. A city needs [bestOfMinPlaces] such places, the
/// first [bestOfAwardedRanks] get the seal. Lists start with [firstBestOfYear].
const firstBestOfYear = 2026;
const bestOfMinReviews = 10;
const bestOfMinPlaces = 5;
const bestOfAwardedRanks = 3;
