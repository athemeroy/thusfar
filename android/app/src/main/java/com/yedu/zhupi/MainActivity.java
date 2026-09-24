package com.yedu.zhupi;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.os.Build;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.webkit.CookieManager;
import android.webkit.JavascriptInterface;
import android.webkit.URLUtil;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;

import com.chaquo.python.Python;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.LinkedHashSet;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Native file access and controls for the reader; model traffic stays in the application. */
public class MainActivity extends Activity {
    private static final int PICK_FILE = 7;
    private static final int SAVE_FILE = 8;
    private static final long MAX_DOWNLOAD = 256L * 1024L * 1024L;
    private WebView web;
    private ValueCallback<Uri[]> pendingPick;
    private String pendingDownload;
    private boolean reading;
    private boolean volumePaging = true;
    private boolean destroyed;
    private boolean downloading;
    private final ExecutorService downloads = Executors.newSingleThreadExecutor();
    private final ExecutorService startup = Executors.newSingleThreadExecutor();

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        web = new WebView(this);
        web.setBackgroundColor(0xFFF4EFE4);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setTextZoom(100);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(true);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        s.setSupportZoom(true);
        s.setBuiltInZoomControls(true);
        s.setDisplayZoomControls(false);
        s.setUserAgentString(s.getUserAgentString() + " YeduApp/1.7.0 YeduStandalone/1");
        CookieManager.getInstance().setAcceptCookie(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(web, false);
        web.addJavascriptInterface(new Bridge(), "YeduApp");
        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest req) {
                String address = req.getUrl().toString();
                if (NavigationPolicy.sameOrigin(address)) return false;
                if (req.isForMainFrame() && req.hasGesture()) {
                    String scheme = req.getUrl().getScheme();
                    if ("https".equalsIgnoreCase(scheme) || "http".equalsIgnoreCase(scheme)) {
                        try { startActivity(new Intent(Intent.ACTION_VIEW, req.getUrl())); }
                        catch (ActivityNotFoundException e) { toast(UiLanguage.get(MainActivity.this, R.string.no_browser)); }
                    }
                }
                return true;
            }

            @Override
            public void onReceivedError(WebView view, WebResourceRequest req, WebResourceError err) {
                // A working service worker serves downloaded books before this callback.
                if (req.isForMainFrame()) view.loadUrl("file:///android_asset/offline.html");
            }
        });
        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback, FileChooserParams params) {
                if (pendingPick != null) pendingPick.onReceiveValue(null);
                pendingPick = callback;
                Intent pick = new Intent(Intent.ACTION_OPEN_DOCUMENT);
                pick.addCategory(Intent.CATEGORY_OPENABLE);
                pick.setType("*/*");
                pick.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, params.getMode() == FileChooserParams.MODE_OPEN_MULTIPLE);
                pick.putExtra(Intent.EXTRA_MIME_TYPES, new String[]{"text/plain", "application/json", "text/json",
                        "application/epub+zip",
                        "application/octet-stream"});
                try { startActivityForResult(Intent.createChooser(pick, UiLanguage.get(MainActivity.this, R.string.pick_title)), PICK_FILE); }
                catch (ActivityNotFoundException e) {
                    pendingPick.onReceiveValue(null);
                    pendingPick = null;
                    toast(UiLanguage.get(MainActivity.this, R.string.no_picker));
                }
                return true;
            }
        });
        web.setDownloadListener((url, userAgent, disposition, mime, length) -> {
            if (!NavigationPolicy.downloadable(url)) { toast(UiLanguage.get(this, R.string.unsupported_save)); return; }
            if (pendingDownload != null || downloading) { toast(UiLanguage.get(this, R.string.save_busy)); return; }
            if (length > MAX_DOWNLOAD) { toast(UiLanguage.get(this, R.string.file_too_large)); return; }
            pendingDownload = url;
            Intent save = new Intent(Intent.ACTION_CREATE_DOCUMENT);
            save.addCategory(Intent.CATEGORY_OPENABLE);
            String type = url.contains("/notebook.md") ? "text/markdown" : url.contains("/export") ? "application/json" : "application/vnd.android.package-archive";
            save.setType(type);
            String name = URLUtil.guessFileName(url, disposition, type);
            if (url.contains("/export") && !name.endsWith(".json")) name += ".yedu.json";
            save.putExtra(Intent.EXTRA_TITLE, name);
            try { startActivityForResult(save, SAVE_FILE); }
            catch (ActivityNotFoundException e) { pendingDownload = null; toast(UiLanguage.get(this, R.string.no_saver)); }
        });
        setContentView(web);
        paintBars("#F4EFE4", false);
        if (state != null) pendingDownload = state.getString("pendingDownload");
        web.loadUrl("file:///android_asset/offline.html");
        startup.submit(() -> {
            try {
                String result = Python.getInstance().getModule("android_bootstrap")
                        .callAttr("start", new File(getFilesDir(), "yedu").getAbsolutePath()).toString();
                String[] parts = result.split("\\n", 2);
                int port = Integer.parseInt(parts[0]);
                if (parts.length != 2 || parts[1].isEmpty()) throw new IllegalStateException("Missing session");
                NavigationPolicy.setLocalPort(port);
                String home = NavigationPolicy.home();
                runOnUiThread(() -> {
                    if (destroyed) return;
                    CookieManager.getInstance().setCookie(home,
                            "yedu=" + parts[1] + "; Path=/; HttpOnly; SameSite=Lax",
                            success -> { if (success && !destroyed) web.loadUrl(home); });
                });
            } catch (Exception e) {
                android.util.Log.e("Yedu", "本地书房启动失败", e);
                toast(UiLanguage.get(this, R.string.local_start_failed));
            }
        });
    }

    private void toast(String text) {
        runOnUiThread(() -> { if (!destroyed) Toast.makeText(this, text, Toast.LENGTH_LONG).show(); });
    }

    private void saveDownload(String address, Uri target) {
        if (!NavigationPolicy.downloadable(address) || !"content".equals(target.getScheme())) {
            toast(UiLanguage.get(this, R.string.invalid_destination)); return;
        }
        final String cookie = CookieManager.getInstance().getCookie(address);
        downloading = true;
        toast(UiLanguage.get(this, R.string.saving));
        downloads.submit(() -> {
            File temporary = null;
            HttpURLConnection connection = null;
            try {
                temporary = File.createTempFile("yedu-export-", ".part", getCacheDir());
                connection = (HttpURLConnection) new URL(address).openConnection();
                connection.setInstanceFollowRedirects(false);
                connection.setConnectTimeout(15000);
                connection.setReadTimeout(30000);
                connection.setRequestProperty("Accept-Encoding", "identity");
                if (cookie != null) connection.setRequestProperty("Cookie", cookie);
                if (connection.getResponseCode() != 200) throw new java.io.IOException("response");
                long expected = connection.getContentLengthLong();
                if (expected > MAX_DOWNLOAD) throw new java.io.IOException("size");
                long total = 0;
                byte[] buffer = new byte[16384];
                // Validate the complete bounded transfer before touching the selected document.
                try (InputStream in = connection.getInputStream(); OutputStream out = new FileOutputStream(temporary)) {
                    for (int n; (n = in.read(buffer)) != -1;) {
                        if (Thread.currentThread().isInterrupted()) throw new java.io.InterruptedIOException();
                        total += n;
                        if (total > MAX_DOWNLOAD) throw new java.io.IOException("size");
                        out.write(buffer, 0, n);
                    }
                }
                if (total == 0 || (expected >= 0 && total != expected)) throw new java.io.IOException("incomplete");
                try (InputStream in = new FileInputStream(temporary);
                     OutputStream out = getContentResolver().openOutputStream(target, "wt")) {
                    if (out == null) throw new java.io.IOException("destination");
                    for (int n; (n = in.read(buffer)) != -1;) {
                        if (Thread.currentThread().isInterrupted()) throw new java.io.InterruptedIOException();
                        out.write(buffer, 0, n);
                    }
                    out.flush();
                }
                toast(UiLanguage.get(this, R.string.saved));
            } catch (Exception e) {
                toast(UiLanguage.get(this, R.string.save_failed));
            } finally {
                if (connection != null) connection.disconnect();
                if (temporary != null) temporary.delete();
                runOnUiThread(() -> downloading = false);
            }
        });
    }

    private void paintBars(String color, boolean dark) {
        int c;
        try { c = Color.parseColor(color); } catch (IllegalArgumentException e) { return; }
        Window w = getWindow();
        w.setStatusBarColor(c);
        w.setNavigationBarColor(c);
        int light = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR;
        int flags = w.getDecorView().getSystemUiVisibility();
        w.getDecorView().setSystemUiVisibility(dark ? flags & ~light : flags | light);
    }

    private void immersive(boolean on) {
        View decor = getWindow().getDecorView();
        int light = decor.getSystemUiVisibility()
                & (View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        int base = View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN;
        decor.setSystemUiVisibility(on ? base | light | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY : light);
    }

    /** Only local reader controls are exposed to JavaScript; no arbitrary network bridge. */
    private class Bridge {
        @JavascriptInterface
        public void setAppLanguage(String code) {
            UiLanguage.save(MainActivity.this, code);
        }

        @JavascriptInterface
        public String getAppLanguage() {
            return UiLanguage.preference(MainActivity.this);
        }

        @JavascriptInterface
        public void setBars(String color, boolean dark) {
            runOnUiThread(() -> { if (!destroyed) paintBars(color, dark); });
        }

        @JavascriptInterface
        public void setVolumePaging(boolean enabled) {
            runOnUiThread(() -> volumePaging = enabled);
        }

        @JavascriptInterface
        public void reading(boolean on, boolean fullscreen) {
            runOnUiThread(() -> {
                if (destroyed) return;
                reading = on;
                if (on) getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                else getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                immersive(on && fullscreen);
            });
        }

        @JavascriptInterface
        public void processingStarted() {
            runOnUiThread(() -> {
                if (destroyed) return;
                Intent service = new Intent(MainActivity.this, ProcessingService.class);
                if (Build.VERSION.SDK_INT >= 26) startForegroundService(service);
                else startService(service);
                if (Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission("android.permission.POST_NOTIFICATIONS") != android.content.pm.PackageManager.PERMISSION_GRANTED)
                    requestPermissions(new String[]{"android.permission.POST_NOTIFICATIONS"}, 9);
            });
        }
    }

    @Override
    protected void onActivityResult(int code, int resultCode, Intent data) {
        if (code == PICK_FILE && pendingPick != null) {
            LinkedHashSet<Uri> chosen = new LinkedHashSet<>();
            if (resultCode == RESULT_OK && data != null) {
                ClipData clip = data.getClipData();
                if (clip != null) for (int i = 0; i < clip.getItemCount(); i++) chosen.add(clip.getItemAt(i).getUri());
                if (data.getData() != null) chosen.add(data.getData());
                chosen.removeIf(uri -> uri == null || !"content".equals(uri.getScheme()));
            }
            pendingPick.onReceiveValue(chosen.isEmpty() ? null : chosen.toArray(new Uri[0]));
            pendingPick = null;
            return;
        }
        if (code == SAVE_FILE) {
            String address = pendingDownload;
            pendingDownload = null;
            if (address != null && resultCode == RESULT_OK && data != null && data.getData() != null)
                saveDownload(address, data.getData());
            return;
        }
        super.onActivityResult(code, resultCode, data);
    }

    @Override
    public boolean onKeyDown(int code, KeyEvent event) {
        if (NavigationPolicy.handlesVolume(reading, volumePaging)
                && (code == KeyEvent.KEYCODE_VOLUME_DOWN || code == KeyEvent.KEYCODE_VOLUME_UP)) {
            web.evaluateJavascript("window.YeduReader && YeduReader.page(" + (code == KeyEvent.KEYCODE_VOLUME_DOWN ? 1 : -1) + ")", null);
            return true;
        }
        return super.onKeyDown(code, event);
    }

    @Override
    public boolean onKeyUp(int code, KeyEvent event) {
        if (NavigationPolicy.handlesVolume(reading, volumePaging)
                && (code == KeyEvent.KEYCODE_VOLUME_DOWN || code == KeyEvent.KEYCODE_VOLUME_UP)) return true;
        return super.onKeyUp(code, event);
    }

    @Override
    public void onBackPressed() {
        web.evaluateJavascript("Boolean(window.YeduReader && YeduReader.onNativeBack && YeduReader.onNativeBack())", consumed -> {
            if (destroyed || "true".equals(consumed)) return;
            if (web.canGoBack()) web.goBack(); else MainActivity.super.onBackPressed();
        });
    }

    @Override
    protected void onPause() {
        CookieManager.getInstance().flush();
        web.onPause();
        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        super.onPause();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (web != null) web.onResume();
        if (reading) getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }

    @Override
    protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out);
        out.putString("pendingDownload", pendingDownload);
        web.saveState(out);
    }

    @Override
    protected void onDestroy() {
        destroyed = true;
        startup.shutdownNow();
        downloads.shutdownNow();
        if (pendingPick != null) { pendingPick.onReceiveValue(null); pendingPick = null; }
        web.stopLoading();
        web.removeJavascriptInterface("YeduApp");
        if (web.getParent() instanceof ViewGroup) ((ViewGroup) web.getParent()).removeView(web);
        web.destroy();
        super.onDestroy();
    }
}
