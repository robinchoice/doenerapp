import 'package:mailer/mailer.dart' as m;
import 'package:mailer/smtp_server.dart';

import 'config.dart';

typedef MailAttachment = ({String fileName, String contentType, List<int> bytes});

abstract interface class Mailer {
  Future<void> send({
    required String to,
    required String subject,
    required String text,
    String? replyTo,
    MailAttachment? attachment,
    String? html,
    Map<String, String> headers = const {},
  });
}

class SmtpMailer implements Mailer {
  final SmtpServer _server;
  final String _from;

  SmtpMailer(SmtpConfig config, this._from)
      : _server = SmtpServer(
          config.host,
          port: config.port,
          username: config.username,
          password: config.password,
          ssl: config.ssl,
        );

  @override
  Future<void> send({
    required String to,
    required String subject,
    required String text,
    String? replyTo,
    MailAttachment? attachment,
    String? html,
    Map<String, String> headers = const {},
  }) async {
    final message = m.Message()
      ..from = _parseAddress(_from)
      ..recipients.add(to)
      ..subject = subject
      ..text = text
      ..html = html;
    message.headers.addAll(headers);
    if (replyTo != null) message.headers['Reply-To'] = replyTo;
    if (attachment != null) {
      message.attachments.add(
        m.StreamAttachment(Stream.value(attachment.bytes), attachment.contentType, fileName: attachment.fileName),
      );
    }
    // Each SMTP step waits 60 s by default; a hanging server would hold up the request and the shutdown.
    await m.send(message, _server, timeout: const Duration(seconds: 10));
  }

  /// Accepts `Name <mail@host>` or a bare address.
  static m.Address _parseAddress(String value) {
    final match = RegExp(r'^(.*)<(.+)>$').firstMatch(value.trim());
    if (match == null) return m.Address(value.trim());
    return m.Address(match.group(2)!.trim(), match.group(1)!.trim());
  }
}

/// Development fallback when no SMTP server is configured: prints the mail.
class LogMailer implements Mailer {
  @override
  Future<void> send({
    required String to,
    required String subject,
    required String text,
    String? replyTo,
    MailAttachment? attachment,
    String? html,
    Map<String, String> headers = const {},
  }) async {
    print('--- mail to $to${replyTo == null ? '' : ' (reply to $replyTo)'}: $subject\n$text');
    if (attachment != null) print('[attachment ${attachment.fileName}, ${attachment.contentType}, ${attachment.bytes.length} bytes]');
    print('---');
  }
}
