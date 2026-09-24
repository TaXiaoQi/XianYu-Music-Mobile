package com.ryanheise.just_audio;

import android.content.Context;
import androidx.annotation.NonNull;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import java.util.HashMap;
import java.util.List;
import java.util.ArrayList;
import java.util.Map;

public class MainMethodCallHandler implements MethodCallHandler {

    private final Context applicationContext;
    private final BinaryMessenger messenger;

    private final Map<String, AudioPlayer> players = new HashMap<>();

    public MainMethodCallHandler(Context applicationContext,
            BinaryMessenger messenger) {
        this.applicationContext = applicationContext;
        this.messenger = messenger;
    }

    @Override
    public void onMethodCall(MethodCall call, @NonNull Result result) {
        switch (call.method) {
        case "init": {
            String id = call.argument("id");
            // 幂等 init：idle 代理机制会反复「disposePlayer → 同 id init」握手。
            // load 挂死时 dispose 回复丢失/激活被打断会让旧注册残留，此后每次
            // activate 的 init 都报 "already exists"，播放器永久失能直到重启。
            // 撞号时改为摘掉残留实例并重建（dispose 可能阻塞在挂死的
            // ExoPlayer.release 上，故先回包再清理，不拖住 Dart 侧激活）。
            AudioPlayer stale = players.remove(id);
            List<Object> rawAudioEffects = call.argument("androidAudioEffects");
            players.put(
                id,
                new AudioPlayer(
                    applicationContext,
                    messenger,
                    id,
                    call.argument("audioLoadConfiguration"),
                    rawAudioEffects,
                    call.argument("androidOffloadSchedulingEnabled")
                )
            );
            result.success(null);
            if (stale != null) {
                try {
                    stale.dispose();
                } catch (Exception e) {
                }
            }
            break;
        }
        case "disposePlayer": {
            String id = call.argument("id");
            AudioPlayer player = players.get(id);
            if (player != null) {
                // 先摘号再 dispose：dispose 抛异常时若后摘号，残留的 id 会让
                // 同实例下一次 init 报 "Platform player already exists"。
                // dispose 本体可能阻塞在挂死的 ExoPlayer.release 上（此时
                // Dart 侧有超时兜底并整体重建新实例），这里不吞结果语义。
                players.remove(id);
                try {
                    player.dispose();
                } catch (Exception e) {
                }
            }
            result.success(new HashMap<String, Object>());
            break;
        }
        case "disposeAllPlayers": {
            dispose();
            result.success(new HashMap<String, Object>());
            break;
        }
        default:
            result.notImplemented();
            break;
        }
    }

    void dispose() {
        for (AudioPlayer player : new ArrayList<AudioPlayer>(players.values())) {
            player.dispose();
        }
        players.clear();
    }
}
