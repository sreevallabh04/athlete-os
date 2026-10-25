package com.athleteos.athlete_os.surfaces

import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.athleteos.athlete_os.R
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Quick Settings tile "Water +250 ml". One tap queues 250 ml through the
 * same native queue as the widget (drained idempotently by Flutter) and
 * refreshes the widget. On the lock screen it asks to unlock first so a
 * pocket tap cannot log water.
 */
class WaterTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        render(null)
    }

    override fun onClick() {
        super.onClick()
        if (isLocked) unlockAndRun { log() } else log()
    }

    private fun log() {
        val logged = try {
            SurfaceActions.logWater(applicationContext, "qs_tile")
        } catch (_: Throwable) {
            false
        }
        if (logged) {
            val t = LocalTime.now().format(DateTimeFormatter.ofPattern("HH:mm", Locale.getDefault()))
            render("+${SurfaceActions.WATER_ML} ml saved · $t")
        }
    }

    private fun render(subtitle: String?) {
        val tile = qsTile ?: return
        tile.label = getString(R.string.surf_tile_label)
        tile.icon = Icon.createWithResource(this, R.drawable.ic_surf_water)
        // An action, not a toggle: never shown as "on".
        tile.state = Tile.STATE_INACTIVE
        if (Build.VERSION.SDK_INT >= 29) {
            tile.subtitle = subtitle ?: "Tap to log"
        }
        tile.contentDescription = "Log 250 millilitres of water"
        tile.updateTile()
    }
}
