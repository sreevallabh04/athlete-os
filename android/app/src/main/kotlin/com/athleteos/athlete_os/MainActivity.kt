package com.athleteos.athlete_os

import android.content.Intent
import android.os.Bundle
import com.athleteos.athlete_os.assistant.AssistantChannels
import com.athleteos.athlete_os.assistant.ShareIntake
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

// FlutterFragmentActivity is required by the `health` plugin to launch the
// Health Connect permission contract.
class MainActivity : FlutterFragmentActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        AssistantChannels(this).register(flutterEngine)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) ShareIntake.handle(intent, EXTRA_OPEN_ROUTE)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        ShareIntake.handle(intent, EXTRA_OPEN_ROUTE)
    }

    companion object {
        /** In-app route to open, set by assistant notifications. */
        const val EXTRA_OPEN_ROUTE = "athlete_os.open_route"
    }
}
