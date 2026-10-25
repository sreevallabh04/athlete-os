import 'package:flutter/widgets.dart';

/// Root navigator, used by full-screen routes so they cover the bottom bar.
final rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');

/// All route paths in one place.
abstract final class AppPaths {
  static const today = '/today';
  static const train = '/train';
  static const strength = '/strength';
  static const running = '/running';
  static const activityDetail = '/running/activity/:id';
  static const workoutDetail = '/workout/:id';
  static const nutrition = '/nutrition';
  static const addFood = '/nutrition/add';
  static const nutritionHistory = '/nutrition/history';
  static const hydration = '/hydration';
  static const coach = '/coach';
  static const aiSettings = '/settings/ai';
  static const aiMemory = '/coach/memory';
  static const aiHistory = '/coach/history';
  static const life = '/life';
  static const habits = '/habits';
  static const mood = '/mood';
  static const journal = '/journal';
  static const notificationSettings = '/settings/notifications';
  static const steps = '/steps';
  static const healthOverview = '/health';
  static const healthStatus = '/integrations/health';
  static const integrations = '/integrations';
  static const calendar = '/calendar';
  static const competition = '/competition';
  static const planner = '/planner';
  static const reports = '/reports';
  static const settings = '/settings';
  static const profile = '/settings/profile';
  static const privacy = '/settings/privacy';
  static const assistant = '/assistant';
  static const assistantSettings = '/assistant/settings';
  static const assistantAudit = '/assistant/audit';
  static const capabilities = '/settings/capabilities';
  static const onboarding = '/onboarding';
  static const program = '/train/program';
  static const routine = '/routine';

  /// HUD component gallery (developer QA).
  static const devGallery = '/dev/gallery';
}
