package dev.opentetrd;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Typeface;
import android.os.Build;
import android.os.Bundle;
import android.view.Gravity;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

public final class MainActivity extends Activity {
    private TextView status;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 10);
        }

        int pad = Math.round(24 * getResources().getDisplayMetrics().density);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER_HORIZONTAL);
        root.setPadding(pad, pad * 2, pad, pad);

        TextView title = new TextView(this);
        title.setText("OpenTetrd");
        title.setTextSize(30);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        root.addView(title);

        TextView explanation = new TextView(this);
        explanation.setText("USB를 통해 휴대폰 인터넷을 Mac의 로컬 SOCKS 프록시에 전달합니다.\n"
                + "시스템 VPN이나 휴대폰 테더링 설정은 변경하지 않습니다.");
        explanation.setTextSize(16);
        explanation.setGravity(Gravity.CENTER);
        explanation.setPadding(0, pad, 0, pad);
        root.addView(explanation);

        status = new TextView(this);
        status.setText(RelayService.running ? "릴레이 실행 중 · 127.0.0.1:8787" : "릴레이 중지됨");
        status.setTextSize(17);
        status.setPadding(0, 0, 0, pad);
        root.addView(status);

        Button start = new Button(this);
        start.setText("릴레이 시작");
        start.setOnClickListener(v -> {
            Intent intent = new Intent(this, RelayService.class);
            intent.setAction(RelayService.ACTION_START);
            startForegroundService(intent);
            status.setText("릴레이 시작 중 · 127.0.0.1:8787");
        });
        root.addView(start, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        Button stop = new Button(this);
        stop.setText("릴레이 중지");
        stop.setOnClickListener(v -> {
            Intent intent = new Intent(this, RelayService.class);
            intent.setAction(RelayService.ACTION_STOP);
            startService(intent);
            status.setText("릴레이 중지됨");
        });
        LinearLayout.LayoutParams stopParams = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        stopParams.topMargin = pad / 2;
        root.addView(stop, stopParams);
        setContentView(root);
    }
}
