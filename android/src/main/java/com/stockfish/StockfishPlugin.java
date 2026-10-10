package com.stockfish;

import android.content.Context;

import androidx.annotation.NonNull;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

/**
 * Exposes the app's native library directory to Dart. The Stockfish engine is
 * shipped as the executable {@code libstockfish_bin.so}, which the installer
 * extracts there; Dart then starts it with {@code Process.start}.
 */
public class StockfishPlugin implements FlutterPlugin, MethodCallHandler {
  private static final String CHANNEL = "stockfish_engine_flutter";

  private MethodChannel channel;
  private Context context;

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    context = binding.getApplicationContext();
    channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
    if (call.method.equals("nativeLibraryDir")) {
      result.success(context.getApplicationInfo().nativeLibraryDir);
    } else {
      result.notImplemented();
    }
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    channel.setMethodCallHandler(null);
    channel = null;
    context = null;
  }
}
