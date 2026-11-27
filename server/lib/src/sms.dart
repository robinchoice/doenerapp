import 'dart:convert';

import 'package:http/http.dart' as http;

/// Only codes that confirm a phone number go out by SMS.
abstract interface class SmsSender {
  Future<void> send(String to, String text);
}

/// Through seven.io (Kiel). Code 100 means the gateway accepted the SMS.
class SevenSms implements SmsSender {
  final String _key;
  final http.Client _client;
  SevenSms(this._key, this._client);

  @override
  Future<void> send(String to, String text) async {
    final response = await _client.post(
      Uri.parse('https://gateway.seven.io/api/sms'),
      headers: {'X-Api-Key': _key, 'Accept': 'application/json'},
      body: {'to': to, 'text': text, 'from': 'Doener'},
    ).timeout(const Duration(seconds: 10));
    Object? answer;
    try {
      answer = jsonDecode(response.body);
    } on FormatException {
      answer = null;
    }
    final code = answer is Map ? answer['success'] : null;
    if (response.statusCode != 200 || code != '100') {
      throw StateError('SMS not accepted: HTTP ${response.statusCode}, code ${code ?? 'none'}');
    }
  }
}

/// For development without an account. Never in production: the log would hold numbers and codes.
class LogSms implements SmsSender {
  const LogSms();

  @override
  Future<void> send(String to, String text) async => print('--- SMS to $to: $text');
}
