// Hands an iOS release build to the external TestFlight group and submits it
// for the beta review — run by the Mobile workflow for tags `v*` only, since
// every build given to the group mails all external testers.
//
//   ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_P8=<base64 .p8> dart run tool/testflight_release.dart <build number>
import 'dart:io';

import 'package:doener_server/doener_server.dart';
import 'package:http/http.dart' as http;

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/testflight_release.dart <build number>');
    exit(64);
  }
  final asc = Config.fromEnvironment(Platform.environment).asc;
  if (asc == null) {
    stderr.writeln('ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 are required');
    exit(1);
  }
  final testFlight = TestFlight(asc, http.Client());
  // Apple needs a few minutes, sometimes more, to process an upload.
  for (var attempt = 0; attempt < 60; attempt++) {
    if (await testFlight.distributeBuild(args.single)) {
      print('Build ${args.single} is in "${asc.group}" and submitted for the beta review');
      exit(0);
    }
    print('Build ${args.single} is still processing …');
    await Future<void>.delayed(const Duration(minutes: 1));
  }
  stderr.writeln('Build ${args.single} was not processed within an hour');
  exit(1);
}
