import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/theme/tokens.dart';

const kStravaOrange = Color(0xFFFC5200);

/// "Connect with Strava" button in Strava's orange style, 48 dp tall.
class ConnectWithStravaButton extends StatelessWidget {
  const ConnectWithStravaButton({super.key, required this.onPressed});
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Connect with Strava',
      excludeSemantics: true,
      child: SizedBox(
        height: 48,
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: kStravaOrange,
            foregroundColor: Colors.white,
            disabledBackgroundColor: kStravaOrange.withValues(alpha: 0.4),
            disabledForegroundColor: Colors.white70,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          ),
          onPressed: onPressed,
          child: const Text.rich(
            TextSpan(
              children: [
                TextSpan(text: 'Connect with '),
                TextSpan(
                  text: 'STRAVA',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }
}

/// "Powered by Strava" attribution for screens showing Strava data.
class PoweredByStrava extends StatelessWidget {
  const PoweredByStrava({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Semantics(
      label: 'Powered by Strava',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'POWERED BY ',
              style: t.labelSmall?.copyWith(
                letterSpacing: 1,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              'STRAVA',
              style: t.labelLarge?.copyWith(
                color: kStravaOrange,
                fontWeight: FontWeight.w900,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Uri stravaActivityUri(String stravaId) =>
    Uri.parse('https://www.strava.com/activities/$stravaId');

/// "View on Strava" link (bold, Strava orange, underlined).
class ViewOnStravaLink extends StatelessWidget {
  const ViewOnStravaLink({super.key, required this.stravaId});
  final String stravaId;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      link: true,
      label: 'View on Strava',
      excludeSemantics: true,
      child: InkWell(
        onTap: () => launchUrl(
          stravaActivityUri(stravaId),
          mode: LaunchMode.externalApplication,
        ),
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
          child: Text(
            'View on Strava',
            style: TextStyle(
              color: kStravaOrange,
              fontWeight: FontWeight.w700,
              decoration: TextDecoration.underline,
              decorationColor: kStravaOrange,
            ),
          ),
        ),
      ),
    );
  }
}
