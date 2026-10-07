package com.ryanheise.audioservice;

import android.content.Context;
import android.os.Bundle;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;

public class AudioServiceActivity extends FlutterActivity {
    @Override
    public FlutterEngine provideFlutterEngine(@NonNull Context context) {
        return AudioServicePlugin.getFlutterEngine(context);
    }

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // 用户划掉多任务后 3s 兜底杀进程前重新打开 app：取消兜底，防误杀冷启动。
        AudioService.cancelTaskRemovedKill();
    }
}
