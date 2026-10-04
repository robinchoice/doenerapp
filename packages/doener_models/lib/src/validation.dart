/// Input rules enforced by the server and mirrored in the app's forms.
abstract final class Validation {
  static const displayNameMin = 2;
  static const displayNameMax = 30;
  static const reviewTextMax = 2000;
  static const feedbackMin = 5;
  static const feedbackMax = 5000;
  static const shopNameMin = 2;

  /// New accounts get a placeholder name with this prefix until the user picks one.
  static const generatedNamePrefix = 'Döner-Fan-';

  static final _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
  static final _generatedName = RegExp('^$generatedNamePrefix\\d+\$');

  static String normalizeEmail(String email) => email.trim().toLowerCase();

  static bool isValidEmail(String email) {
    final e = normalizeEmail(email);
    return e.length <= 254 && _email.hasMatch(e);
  }

  /// Returns a German error message, or null if the name is valid.
  static String? displayNameError(String name) {
    final trimmed = name.trim();
    if (trimmed.length < displayNameMin || trimmed.length > displayNameMax) {
      return '$displayNameMin bis $displayNameMax Zeichen.';
    }
    if (isGeneratedName(trimmed)) return 'Bitte wähle einen eigenen Namen.';
    return null;
  }

  /// True for the placeholder name a new account starts with.
  static bool isGeneratedName(String name) => _generatedName.hasMatch(name.trim());

  static bool isValidRating(int? value) => value == null || (value >= 1 && value <= 5);

  /// Trims and turns empty strings into null.
  static String? clean(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
