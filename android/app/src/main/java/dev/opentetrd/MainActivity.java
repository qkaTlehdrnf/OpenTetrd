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
        explanation.setText("Forwards this phone's internet access to a local SOCKS proxy "
                + "on your Mac over USB.\n"
                + "It does not change the system VPN or phone tethering settings.");
        explanation.setTextSize(16);
        explanation.setGravity(Gravity.CENTER);
        explanation.setPadding(0, pad, 0, pad);
        root.addView(explanation);

        status = new TextView(this);
        status.setTextSize(17);
        status.setPadding(0, 0, 0, pad);
        root.addView(status);

        Button start = new Button(this);
        start.setText("Start relay");
        start.setOnClickListener(v -> {
            Intent intent = new Intent(this, RelayService.class);
            intent.setAction(RelayService.ACTION_START);
            startForegroundService(intent);
            status.setText("Starting relay · 127.0.0.1:8787");
        });
        root.addView(start, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        Button stop = new Button(this);
        stop.setText("Stop relay");
        stop.setOnClickListener(v -> {
            Intent intent = new Intent(this, RelayService.class);
            intent.setAction(RelayService.ACTION_STOP);
            startService(intent);
            status.setText("Relay stopped");
        });
        LinearLayout.LayoutParams stopParams = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        stopParams.topMargin = pad / 2;
        root.addView(stop, stopParams);
        setContentView(root);
        refreshStatus();
    }

    @Override
    protected void onResume() {
        super.onResume();
        // onCreate does not run when returning from the background, so the label would
        // otherwise keep showing whatever the relay state was when the activity was built.
        refreshStatus();
    }

    private void refreshStatus() {
        if (RelayService.running) {
            status.setText("Relay running · 127.0.0.1:8787");
        } else if (RelayService.lastError != null) {
            status.setText("Relay stopped · " + RelayService.lastError);
        } else {
            status.setText("Relay stopped");
        }
    }
}
