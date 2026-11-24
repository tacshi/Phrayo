import 'package:flutter/widgets.dart';

/// Apple's iOS system colours, the palette SwiftUI views use by default, in
/// light and dark appearance.
///
/// The `…Fill` colours are the matching accent at low opacity over a card,
/// as tinted iOS buttons draw them; the `…Text` colours are the accessible
/// accent variants for text on those fills.
class AppleColors {
  const AppleColors._({
    required this.blue,
    required this.blueFill,
    required this.blueText,
    required this.indigo,
    required this.indigoFill,
    required this.indigoText,
    required this.red,
    required this.redFill,
    required this.redText,
    required this.green,
    required this.orange,
    required this.gray,
    required this.control,
    required this.label,
    required this.secondaryLabel,
    required this.separator,
    required this.opaqueSeparator,
    required this.groupedBackground,
    required this.secondaryGroupedBackground,
    required this.elevated,
    required this.chrome,
    required this.tertiaryFill,
    required this.toast,
  });

  /// systemBlue, the default SwiftUI accent.
  final Color blue, blueFill, blueText;
  final Color indigo, indigoFill, indigoText;

  /// systemRed, for destructive actions and live recording.
  final Color red, redFill, redText;
  final Color green, orange;

  /// systemGray, for unselected tab items.
  final Color gray;

  /// The grey behind secondary round controls.
  final Color control;
  final Color label, secondaryLabel;
  final Color separator, opaqueSeparator;

  /// The page behind grouped lists, and the cards on it.
  final Color groupedBackground, secondaryGroupedBackground;

  /// Raised surfaces such as alerts and menus.
  final Color elevated;

  /// Tab bars and scrolled navigation bars.
  final Color chrome;

  /// The fill of text and search fields.
  final Color tertiaryFill;

  /// Transient messages.
  final Color toast;

  static const light = AppleColors._(
    blue: Color(0xFF007AFF),
    blueFill: Color(0xFFD9EBFF),
    blueText: Color(0xFF0040DD),
    indigo: Color(0xFF5856D6),
    indigoFill: Color(0xFFE6E6F9),
    indigoText: Color(0xFF3634A3),
    red: Color(0xFFFF3B30),
    redFill: Color(0xFFFFE2E0),
    redText: Color(0xFFD70015),
    green: Color(0xFF34C759),
    orange: Color(0xFFFF9500),
    gray: Color(0xFF8E8E93),
    control: Color(0xFFE5E5EA),
    label: Color(0xFF000000),
    secondaryLabel: Color(0x993C3C43),
    separator: Color(0x4A3C3C43),
    opaqueSeparator: Color(0xFFC6C6C8),
    groupedBackground: Color(0xFFF2F2F7),
    secondaryGroupedBackground: Color(0xFFFFFFFF),
    elevated: Color(0xFFFFFFFF),
    chrome: Color(0xFFF9F9F9),
    tertiaryFill: Color(0x1F767680),
    toast: Color(0xFF1C1C1E),
  );

  static const dark = AppleColors._(
    blue: Color(0xFF0A84FF),
    blueFill: Color(0xFF183350),
    blueText: Color(0xFF409CFF),
    indigo: Color(0xFF5E5CE6),
    indigoFill: Color(0xFF2A2A4A),
    indigoText: Color(0xFF7D7AFF),
    red: Color(0xFFFF453A),
    redFill: Color(0xFF4E2524),
    redText: Color(0xFFFF6961),
    green: Color(0xFF30D158),
    orange: Color(0xFFFF9F0A),
    gray: Color(0xFF8E8E93),
    control: Color(0xFF3A3A3C),
    label: Color(0xFFFFFFFF),
    secondaryLabel: Color(0x99EBEBF5),
    separator: Color(0x99545458),
    opaqueSeparator: Color(0xFF38383A),
    groupedBackground: Color(0xFF000000),
    secondaryGroupedBackground: Color(0xFF1C1C1E),
    elevated: Color(0xFF2C2C2E),
    chrome: Color(0xFF161616),
    tertiaryFill: Color(0x3D767680),
    toast: Color(0xFF3A3A3C),
  );

  static AppleColors of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}
