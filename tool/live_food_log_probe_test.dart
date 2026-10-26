// Manual live probe (not part of the suite's assertions): sends a realistic
// day to the deployed ai-chat with the production food-log prompt + schema.
// Run: flutter test tool/live_food_log_probe_test.dart --dart-define-from-file=config/dev.json
import 'dart:convert';
import 'dart:io';

import 'package:athlete_os/core/config/env.dart';
import 'package:athlete_os/features/coach/data/ai_food_log_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('live food-log parse (fast mode)', () async {
    if (!Env.hasSupabase) return;
    final http = HttpClient();
    Future<Map<String, dynamic>> post(
      String path,
      Object body, {
      String? token,
    }) async {
      final req = await http.postUrl(Uri.parse('${Env.supabaseUrl}$path'));
      req.headers.set('apikey', Env.supabaseAnonKey);
      req.headers.set('content-type', 'application/json');
      if (token != null) req.headers.set('authorization', 'Bearer $token');
      req.add(utf8.encode(jsonEncode(body)));
      final res = await req.close();
      return jsonDecode(await res.transform(utf8.decoder).join())
          as Map<String, dynamic>;
    }

    final auth = await post('/auth/v1/signup', {});
    final token = auth['access_token'] as String;
    const day =
        'Breakfast: 3 egg omelette with 2 rotis, black coffee. Lunch: 1 '
        'katori dal, 1 cup rice, 100g paneer bhurji, salad. Snack: 1 scoop '
        'whey with banana. Dinner: 2 besan chillas with curd';
    final sw = Stopwatch()..start();
    final res = await post('/functions/v1/ai-chat', {
      'request_id': 'probe${DateTime.now().millisecondsSinceEpoch}',
      'system': foodLogSystemPrompt,
      'messages': [
        {
          'role': 'user',
          'content': [
            {
              'type': 'text',
              'text': foodLogUserMessage(day, DateTime(2026, 10, 26, 21)),
            },
          ],
        },
      ],
      'tools': [
        {
          'name': logFoodItemsTool,
          'description': 'Return every food and drink in the log.',
          'input_schema': logFoodItemsSchema,
        },
      ],
      'preferences': {
        'max_tokens': foodLogMaxTokens,
        'primary_provider': 'groq',
      },
    }, token: token);
    sw.stop();
    final call = (res['content'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((b) => b['type'] == 'tool_call', orElse: () => {});
    final items = ((call['arguments'] as Map?)?['items'] as List? ?? const [])
        .cast<Map>();
    var total = 0.0;
    // ignore: avoid_print
    print(
      'provider=${res['provider']} model=${res['model']} '
      '${sw.elapsedMilliseconds} ms, ${items.length} items',
    );
    for (final i in items) {
      total += (i['kcal'] as num).toDouble();
      // ignore: avoid_print
      print(
        '  ${i['meal_type']}: ${i['name']} (${i['quantity_description']}) '
        '${i['kcal']} kcal P${i['protein_g']}',
      );
    }
    // ignore: avoid_print
    print('total ${total.round()} kcal');
    http.close();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
