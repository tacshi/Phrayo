import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/languages.dart';

bool usesGoogleTranslation(AppSettings settings) =>
    defaultTargetPlatform == TargetPlatform.android &&
    !settings.usesTextModel &&
    !isCantonese(settings.source) &&
    !isCantonese(settings.target) &&
    sonioxLanguageCode(settings.source) != sonioxLanguageCode(settings.target);

class TranslationAttribution extends StatelessWidget {
  const TranslationAttribution({super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: InkWell(
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Google Translate'),
          content: const SingleChildScrollView(
            child: SelectableText(
              'Android offline translations use Google Translate.\n\n'
              'Google disclaims warranties for these automatic translations, including accuracy, '
              'reliability, merchantability, fitness for a particular purpose and noninfringement.\n\n'
              'https://cloud.google.com/translate\n'
              'https://cloud.google.com/translate/attribution',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(MaterialLocalizations.of(context).closeButtonLabel),
            ),
          ],
        ),
      ),
      child: Image.asset(
        'assets/google_translate/${Theme.of(context).brightness == Brightness.dark ? 'white' : 'color'}.png',
        height: 20,
        semanticLabel: 'Powered by Google Translate',
      ),
    ),
  );
}
