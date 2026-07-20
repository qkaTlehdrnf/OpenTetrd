package dev.opentetrd;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.os.IBinder;
import android.util.Log;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class RelayService extends Service {
    public static final String ACTION_START = "dev.opentetrd.START";
    public static final String ACTION_STOP = "dev.opentetrd.STOP";
    private static final String TAG = "OpenTetrd";
    private static final int PORT = 8787;
    private static final byte[] MAGIC = {'O', 'T', 'R', '1'};
    private static final int NOTIFICATION_ID = 8787;
    private final ExecutorService workers = Executors.newCachedThreadPool();
    private volatile ServerSocket server;
    public static volatile boolean running;

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_STOP.equals(intent.getAction())) {
            stopRelay();
            stopForeground(STOP_FOREGROUND_REMOVE);
            stopSelf();
            return START_NOT_STICKY;
        }
        startForeground(NOTIFICATION_ID, notification());
        startRelay();
        return START_STICKY;
    }

    private Notification notification() {
        String channelId = "relay";
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel(
                channelId, "USB relay", NotificationManager.IMPORTANCE_LOW));
        PendingIntent open = PendingIntent.getActivity(this, 0,
                new Intent(this, MainActivity.class),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(this, channelId)
                .setContentTitle("OpenTetrd 릴레이 실행 중")
                .setContentText("USB 로컬 포트 8787에서 대기 중")
                .setSmallIcon(android.R.drawable.stat_sys_upload_done)
                .setContentIntent(open)
                .setOngoing(true)
                .build();
    }

    private synchronized void startRelay() {
        if (running) return;
        running = true;
        workers.execute(() -> {
            try (ServerSocket listener = new ServerSocket()) {
                server = listener;
                listener.bind(new InetSocketAddress(InetAddress.getLoopbackAddress(), PORT), 16);
                Log.i(TAG, "relay listening on 127.0.0.1:" + PORT);
                while (running) {
                    Socket local = listener.accept();
                    workers.execute(() -> handle(local));
                }
            } catch (IOException error) {
                if (running) Log.e(TAG, "relay listener failed", error);
            } finally {
                server = null;
                running = false;
            }
        });
    }

    private void handle(Socket local) {
        Socket remote = null;
        boolean accepted = false;
        try {
            local.setTcpNoDelay(true);
            DataInputStream input = new DataInputStream(local.getInputStream());
            DataOutputStream output = new DataOutputStream(local.getOutputStream());
            byte[] magic = new byte[4];
            input.readFully(magic);
            int type = input.readUnsignedByte();
            int port = input.readUnsignedShort();
            int length = input.readUnsignedShort();
            if (!Arrays.equals(magic, MAGIC) || port == 0 || length < 1 || length > 253) {
                output.writeByte(1);
                output.flush();
                return;
            }
            byte[] address = new byte[length];
            input.readFully(address);
            String host;
            if ((type == 1 && length == 4) || (type == 4 && length == 16)) {
                host = InetAddress.getByAddress(address).getHostAddress();
            } else if (type == 3) {
                host = new String(address, StandardCharsets.US_ASCII);
            } else {
                output.writeByte(1);
                output.flush();
                return;
            }
            remote = new Socket();
            remote.connect(new InetSocketAddress(host, port), 15_000);
            remote.setTcpNoDelay(true);
            output.writeByte(0);
            output.flush();
            accepted = true;
            relayBothWays(local, remote);
            remote = null;
        } catch (IOException error) {
            try {
                if (!accepted && !local.isClosed()) {
                    local.getOutputStream().write(2);
                    local.getOutputStream().flush();
                }
            } catch (IOException ignored) { }
            Log.w(TAG, "relay connection failed: " + error.getMessage());
        } finally {
            closeQuietly(remote);
            closeQuietly(local);
        }
    }

    private void relayBothWays(Socket local, Socket remote) throws IOException {
        Object monitor = new Object();
        int[] finished = {0};
        workers.execute(() -> pump(local, remote, monitor, finished));
        workers.execute(() -> pump(remote, local, monitor, finished));
        synchronized (monitor) {
            while (finished[0] < 2) {
                try {
                    monitor.wait();
                } catch (InterruptedException error) {
                    Thread.currentThread().interrupt();
                    throw new IOException("relay interrupted", error);
                }
            }
        }
        closeQuietly(remote);
    }

    private static void pump(Socket source, Socket destination, Object monitor, int[] finished) {
        try {
            InputStream input = source.getInputStream();
            OutputStream output = destination.getOutputStream();
            byte[] buffer = new byte[64 * 1024];
            for (int count; (count = input.read(buffer)) != -1; ) {
                output.write(buffer, 0, count);
                output.flush();
            }
            try { destination.shutdownOutput(); } catch (IOException ignored) { }
        } catch (IOException ignored) {
        } finally {
            synchronized (monitor) {
                finished[0]++;
                monitor.notifyAll();
            }
        }
    }

    private synchronized void stopRelay() {
        running = false;
        closeQuietly(server);
        server = null;
    }

    private static void closeQuietly(java.io.Closeable closeable) {
        if (closeable != null) {
            try { closeable.close(); } catch (IOException ignored) { }
        }
    }

    @Override
    public void onDestroy() {
        stopRelay();
        workers.shutdownNow();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
