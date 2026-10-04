/// How many reviews of the area's average every place starts with.
const rankingPriorWeight = 3;

/// Weighted average for the ranking: places with few reviews are pulled
/// towards [mean] (the average of all reviews in the area), so a single 5
/// doesn't beat many 4.5s.
double weightedRating(double average, int count, double mean) =>
    (average * count + mean * rankingPriorWeight) / (count + rankingPriorWeight);
