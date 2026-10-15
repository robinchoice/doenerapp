import 'package:shelf/shelf.dart';

/// `/datenschutz` — privacy policy for the app stores and the web app.
Response privacyPage(Request _) => Response.ok(_privacyHtml, headers: {'content-type': 'text/html; charset=utf-8'});

const _privacyHtml = '''<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Datenschutz – Döner App</title>
<style>
  body { margin: 0; font-family: system-ui, sans-serif; background: #fff8f0; color: #222; line-height: 1.5; }
  main { max-width: 680px; margin: 0 auto; padding: 32px 24px 64px; }
  h1 { font-size: 1.75rem; }
  h2 { font-size: 1.15rem; margin-top: 2em; }
  a { color: #c25e00; }
</style>
</head>
<body><main>
<h1>Datenschutz</h1>
<p>Diese Erklärung gilt für die Döner App auf iOS und Android und für die Web-Version unter dieser Adresse. Stand: Oktober 2026.</p>

<h2>1. Verantwortlicher</h2>
<p>Robin Wahl<br>Pleasance<br>Bugginger Straße 37<br>79114 Freiburg<br>E-Mail: <a href="mailto:hello@pleasance.org">hello@pleasance.org</a></p>

<h2>2. Server und Hosting</h2>
<p>Die App spricht nur mit meinem eigenen Server bei der Hetzner Online GmbH (Industriestr. 25, 91710 Gunzenhausen), Serverstandort ist Deutschland. Dort liegen die Datenbank und alle Daten, die unten genannt sind. Bei jedem Aufruf werden technisch IP-Adresse, Zeitpunkt und die aufgerufene Adresse übermittelt und kurzzeitig in Server-Logfiles gespeichert. Rechtsgrundlage ist Art. 6 Abs. 1 lit. f DSGVO (berechtigtes Interesse an einem sicheren und zuverlässigen Betrieb).</p>

<h2>3. Konto und Anmeldung</h2>
<p>Für ein Konto brauchst du nur deine E-Mail-Adresse und einen Anzeigenamen. Zur Anmeldung schickt dir der Server einen Code per E-Mail. Die Mails laufen über Proton (Proton AG, Route de la Galaise 32, 1228 Plan-les-Ouates, Schweiz); für die Schweiz liegt ein Angemessenheitsbeschluss der EU-Kommission vor (Art. 45 DSGVO). Nach der Anmeldung bleibst du bis zu 180 Tage angemeldet. Außerdem speichert der Server, welche Ernährung du eingestellt hast und ob der Expertenmodus an ist. Rechtsgrundlage ist Art. 6 Abs. 1 lit. b DSGVO (Nutzungsvertrag).</p>

<h2>4. Bewertungen, Besuche und Fotos</h2>
<p>Was du in der App einträgst, speichert der Server: Bewertungen mit Text und Fotos, Besuche (Laden und Zeitpunkt), Hinweise auf fehlende Läden und die Zahl deiner Suchen pro Tag (gegen Missbrauch). Bewertungen, Fotos und dein Anzeigename sind für andere Nutzer sichtbar, sie fließen in das Ranking ein. Rechtsgrundlage ist Art. 6 Abs. 1 lit. b DSGVO.</p>

<h2>5. Freunde</h2>
<p>Freunde verbindest du per Einladungslink oder QR-Code. Bestätigte Freunde sehen, wenn du gerade in einem Laden isst. Das zeigt die App nur, wenn du es selbst startest, und es endet automatisch. Rechtsgrundlage ist Art. 6 Abs. 1 lit. b DSGVO.</p>

<h2>6. Standort</h2>
<p>Mit deiner Erlaubnis nutzt die App deinen Standort, um Läden in der Nähe zu zeigen. Dazu schickt sie die Koordinaten an meinen Server, der sie für die Suche verwendet und nicht speichert. Ohne Erlaubnis zeigt die App Freiburg, und du verschiebst die Karte selbst. Rechtsgrundlage ist deine Einwilligung nach Art. 6 Abs. 1 lit. a DSGVO, die du in den Einstellungen deines Geräts jederzeit widerrufen kannst.</p>

<h2>7. Google Maps und Google Places</h2>
<p>Die Karte stammt von Google Maps (Google Ireland Limited, Gordon House, Barrow Street, Dublin 4, Irland). Beim Anzeigen der Karte lädt dein Gerät die Kartendaten direkt von Google; Google erhält dabei deine IP-Adresse und den sichtbaren Kartenausschnitt und kann Daten in die USA übermitteln. Google ist nach dem EU-US Data Privacy Framework zertifiziert. Die Läden selbst fragt mein Server bei Google Places ab; dabei gehen nur die Koordinaten des Suchgebiets an Google, keine Angaben zu dir. Mehr dazu in der <a href="https://policies.google.com/privacy">Datenschutzerklärung von Google</a>. Rechtsgrundlage ist Art. 6 Abs. 1 lit. f DSGVO (berechtigtes Interesse an einer funktionierenden Karte).</p>

<h2>8. Feedback</h2>
<p>Über den Käfer-Knopf oder die Einstellungen kannst du Feedback schicken, auf Wunsch mit einem Screenshot des aktuellen Bildschirms. Der Server speichert die Nachricht mit Screenshot, App-Version und Plattform und schickt sie mir per E-Mail über Proton. Rechtsgrundlage ist Art. 6 Abs. 1 lit. f DSGVO (berechtigtes Interesse an der Verbesserung der App).</p>

<h2>9. Testanfrage</h2>
<p>Auf der Startseite kannst du dich für den Test der iOS- oder Android-App melden. Dafür speichert der Server deine E-Mail-Adresse und die gewählte Plattform und schickt sie mir per E-Mail über Proton. Ich trage die Adresse bei Apple (TestFlight) bzw. Google (Play Console) als Tester ein, damit du die Einladung bekommst; dort gelten die Datenschutzerklärungen von Apple und Google. Der Server löscht die Anfrage nach 90 Tagen. Rechtsgrundlage ist Art. 6 Abs. 1 lit. b DSGVO (deine Anfrage).</p>

<h2>10. Fehlerberichte (GlitchTip)</h2>
<p>Stürzt die App ab oder tritt ein Fehler auf, geht ein Fehlerbericht an GlitchTip. GlitchTip läuft auf meinem eigenen Server bei Hetzner in Deutschland. Der Bericht enthält die Fehlermeldung, die betroffene Stelle im Code sowie Gerätetyp und Systemversion, aber keine Angaben zu deiner Person. GlitchTip löscht die Berichte nach 90 Tagen. Rechtsgrundlage ist Art. 6 Abs. 1 lit. f DSGVO (berechtigtes Interesse an einer fehlerfreien App).</p>

<h2>11. Speicher auf deinem Gerät</h2>
<p>Die App speichert dein Anmelde-Token, deine Einstellungen und eine Kopie deiner Daten auf dem Gerät, damit sie auch offline funktioniert. Erinnerungen nach einem Besuch plant die App lokal, dafür gehen keine Daten an einen Push-Dienst. Es gibt keine Werbung, kein Tracking und keine Analyse-Dienste.</p>

<h2>12. Konto löschen</h2>
<p>Du kannst dein Konto jederzeit in der App unter Einstellungen → Account löschen entfernen. Dabei löscht der Server sofort dein Konto mit allen Bewertungen, Fotos, Besuchen und Freundschaften. Feedback und Hinweise auf Läden bleiben ohne Bezug zu dir erhalten. Du kannst die Löschung auch per E-Mail an <a href="mailto:hello@pleasance.org">hello@pleasance.org</a> verlangen.</p>

<h2>13. Deine Rechte</h2>
<p>Du hast das Recht auf Auskunft, Berichtigung, Löschung, Einschränkung der Verarbeitung, Datenübertragbarkeit und Widerspruch sowie das Recht, eine Einwilligung zu widerrufen. Wende dich dazu an die oben genannte Kontaktadresse. Außerdem hast du das Recht, dich bei einer Datenschutz-Aufsichtsbehörde zu beschweren.</p>
</main></body>
</html>
''';
