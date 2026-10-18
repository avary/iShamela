import 'package:flutter/widgets.dart';

/// Bottom space a scroll view must leave so its last row clears the floating
/// liquid-glass tab bar (and the home indicator). Zero under the classic bar,
/// which the Scaffold already lays out below the body.
///
/// Pages that use this keep `SafeArea(bottom: false)` so content can still
/// scroll behind the translucent bar.
double navBarInset(BuildContext context) =>
    MediaQuery.paddingOf(context).bottom;
