import 'dart:convert';

import '../tools/tool_registry.dart';
import '../tools/tool_spec.dart';

/// Deterministic tool routing: instead of sending all ~23 tool schemas with
/// every request (≈ 4 K tokens on their own), the coach sends a relevant
/// subset chosen from the user's words. Smaller requests are faster on
/// Gemini and fit Groq's free-tier 8 K tokens/minute, so the fallback can
/// actually carry coach turns.
///
/// Rules (pure, unit-tested):
/// * a small [coreTools] set is always included;
/// * each [ToolCategory] whose keywords appear in the message adds its tools
///   (most specific match first);
/// * follow-ups without keywords ("and yesterday?") reuse the tools the
///   conversation used most recently;
/// * no match at all → [generalTools] (a broad daily-overview set);
/// * the result is capped at [maxRoutedTools];
/// * if the model asks for a tool that was not sent, the controller still
///   runs it (it is registered locally) and widens the next call of the turn
///   to the full catalogue.
const maxRoutedTools = 8;

/// Always sent: cheap, schema-less overviews the model can fall back on.
const coreTools = ['get_today_dashboard', 'get_profile_and_goals'];

/// Sent when nothing in the message matched a category.
const generalTools = [
  'get_nutrition_summary',
  'get_steps_summary',
  'get_workout_history',
  'get_calendar_events',
  'get_weekly_report',
  'get_habit_summary',
];

class ToolCategory {
  const ToolCategory(this.id, this.tools, this.keywordList);
  final String id;
  final List<String> tools;

  /// Comma-separated lower-case stems, matched at word starts ("protein"
  /// matches "proteins"); keywords of ≤ 3 letters must match a whole word.
  final String keywordList;
  List<String> get keywords => keywordList.split(',');
}

const toolCategories = <ToolCategory>[
  ToolCategory(
    'nutrition',
    [
      'get_nutrition_summary',
      'search_food_database',
      'log_food',
      'update_food_entry',
    ],
    'eat,ate,food,meal,protein,calor,kcal,carb,fat,macro,breakfast,'
        'lunch,dinner,snack,diet,nutrition,fiber,fibre,hungry,cook,'
        'recipe,chicken,rice,egg,paneer,dal,roti,chapati,oats,shake,whey,'
        'fruit,banana,curd,yogurt,milk',
  ),
  ToolCategory('hydration', [
    'get_water_summary',
    'log_water',
  ], 'water,drink,drank,hydrat,ml,litre,liter,bottle,glass,thirst'),
  ToolCategory(
    'activity',
    [
      'get_steps_summary',
      'get_running_activities',
      'get_strava_activities',
      'analyze_strava_activity',
    ],
    'step,walk,run,ran,jog,km,kilomet,mile,pace,cardio,strava,'
        'distance,5k,10k,marathon,cycl,ride,active',
  ),
  ToolCategory(
    'training',
    ['get_workout_history', 'get_strength_progress', 'get_weekly_report'],
    'workout,train,session,lift,gym,bench,squat,deadlift,press,pr,'
        '1rm,e1rm,set,rep,volume,exercise,strength,muscle,hevy,pull,push,'
        'leg,chest,arm,shoulder,routine,deload',
  ),
  ToolCategory(
    'schedule',
    ['get_calendar_events', 'suggest_schedule'],
    'calendar,schedule,slot,meeting,event,tomorrow,free,busy,when,'
        'plan,time,agenda,diary',
  ),
  ToolCategory(
    'life',
    ['get_habit_summary', 'log_mood', 'get_journal_summary'],
    'habit,streak,mood,feel,energy,stress,journal,tired,anxious,'
        'happy,sad,sleep,slept,rest,motivat,check-in,checkin',
  ),
  ToolCategory(
    'competition',
    ['get_competition_countdown'],
    'competition,compete,meet,race,countdown,until,nationals,event,'
        'peak,taper,contest',
  ),
  ToolCategory(
    'review',
    ['get_weekly_report'],
    'week,weekly,report,review,trend,progress,month,compare,average,'
        'summary,summar,overall,adherence',
  ),
  ToolCategory('memory', [
    'remember_preference',
    'record_recommendation',
  ], 'remember,prefer,always,never,note that,recommend'),
];

/// The outcome of [routeTools]: names in send order plus why (for logs and
/// tests).
class ToolRoute {
  const ToolRoute(this.names, this.categories, {this.reason = 'keywords'});
  final List<String> names;
  final List<String> categories;

  /// keywords | follow_up | general | full
  final String reason;

  List<ToolSpec> get specs => [for (final n in names) ?toolByName(n)];
}

final _wordStart = RegExp(r'[a-z0-9]+');

/// Picks the tools for [message]. [recentTools] are tool names the
/// conversation called recently (newest first) and are used for follow-ups.
ToolRoute routeTools(String message, {List<String> recentTools = const []}) {
  final text = message.toLowerCase();
  final words = _wordStart.allMatches(text).map((m) => m.group(0)!).toList();
  bool hit(String k) {
    if (k.contains(' ') || k.contains('-')) return text.contains(k);
    // Short keywords must match a whole word; stems match word starts.
    if (k.length <= 3) return words.contains(k);
    return words.any((w) => w.startsWith(k));
  }

  final scored = <(ToolCategory, int)>[];
  for (final c in toolCategories) {
    final n = c.keywords.where(hit).length;
    if (n > 0) scored.add((c, n));
  }
  // Most keyword hits first; ties keep catalogue order (stable sort).
  final ordered = [...scored]
    ..sort((a, b) {
      final d = b.$2.compareTo(a.$2);
      if (d != 0) return d;
      return toolCategories
          .indexOf(a.$1)
          .compareTo(toolCategories.indexOf(b.$1));
    });

  final out = <String>[...coreTools];
  void add(String name) {
    if (out.length >= maxRoutedTools || out.contains(name)) return;
    if (toolByName(name) != null) out.add(name);
  }

  var reason = 'keywords';
  if (ordered.isNotEmpty) {
    // Round-robin so a second category still gets its primary tool before
    // the first category's long tail fills the cap.
    final lists = [for (final (c, _) in ordered) c.tools];
    for (var i = 0; out.length < maxRoutedTools; i++) {
      var any = false;
      for (final l in lists) {
        if (i < l.length) {
          any = true;
          add(l[i]);
        }
      }
      if (!any) break;
    }
  } else if (recentTools.isNotEmpty) {
    reason = 'follow_up';
    for (final n in recentTools) {
      add(n);
    }
    for (final n in generalTools) {
      add(n);
    }
  } else {
    reason = 'general';
    for (final n in generalTools) {
      add(n);
    }
  }
  return ToolRoute(out, [for (final (c, _) in ordered) c.id], reason: reason);
}

/// Every registered tool (used when the model asked for a tool it was not
/// given, or for very open questions).
ToolRoute fullToolRoute() =>
    ToolRoute([for (final t in coachTools) t.name], const [], reason: 'full');

// ---------------------------------------------------------------------------
// Request size accounting
// ---------------------------------------------------------------------------

/// Conservative token estimate for JSON-heavy prompts (≈ 3.3 UTF-8 bytes
/// per token for schemas and tool results; prose is closer to 4). Used for
/// budgeting and tests, not billing.
int estimateTokens(String s) => (utf8.encode(s).length / 3.3).ceil();

/// Size of one model request, split by part.
class RequestSize {
  const RequestSize({
    required this.systemTokens,
    required this.toolTokens,
    required this.historyTokens,
    required this.toolCount,
  });

  factory RequestSize.of({
    required String system,
    required List<Map<String, Object?>> tools,
    required List<Map<String, Object?>> messages,
  }) => RequestSize(
    systemTokens: estimateTokens(system),
    toolTokens: estimateTokens(jsonEncode(tools)),
    historyTokens: estimateTokens(jsonEncode(messages)),
    toolCount: tools.length,
  );

  final int systemTokens;
  final int toolTokens;
  final int historyTokens;
  final int toolCount;
  int get total => systemTokens + toolTokens + historyTokens;

  @override
  String toString() =>
      '~$total tok (system $systemTokens, $toolCount tools $toolTokens, '
      'history $historyTokens)';
}
