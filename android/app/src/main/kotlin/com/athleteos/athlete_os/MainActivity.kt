package com.athleteos.athlete_os

import android.content.Intent
import android.os.Bundle
import com.athleteos.athlete_os.assistant.AssistantChannels
import com.athleteos.athlete_os.assistant.ShareIntake
import com.athleteos.athlete_os.surfaces.SurfaceEvents
import com.athleteos.athlete_os.surfaces.SurfacesChannels
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

// FlutterFragmentActivity is required by the `health` plugin to launch the
// Health Connect permission contract.
class MainActivity : FlutterFragmentActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        AssistantChannels(this).register(flutterEngine)
        // Home-screen surfaces (widget, shortcuts, deep links, QS tile).
        SurfacesChannels(this).register(flutterEngine)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        SurfaceEvents.detach()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    // athleteos://open/... links are routed by Dart through an allowlist
    // (lib/features/surfaces/domain/deep_links.dart). Flutter's built-in deep
    // linking would push the raw URI into the router and bypass it.
    override fun shouldHandleDeeplinking(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) {
            ShareIntake.handle(intent, EXTRA_OPEN_ROUTE)
            SurfaceEvents.handleIntent(intent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        ShareIntake.handle(intent, EXTRA_OPEN_ROUTE)
        SurfaceEvents.handleIntent(intent)
    }

    companion object {
        /** In-app route to open, set by assistant notifications. */
        const val EXTRA_OPEN_ROUTE = "athlete_os.open_route"
    }
}
