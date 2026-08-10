package org.omnilink

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import org.omnilink.transport.OmnilinkTransportPlugin

/**
 * Main Android Activity for OMNILINK.
 * Registers native Kotlin plugins (OmnilinkTransportPlugin) with the FlutterEngine.
 */
class MainActivity: FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(OmnilinkTransportPlugin())
    }
}
