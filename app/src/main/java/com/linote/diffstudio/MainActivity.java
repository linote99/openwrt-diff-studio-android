package com.linote.diffstudio;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.res.ColorStateList;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.Editable;
import android.text.InputType;
import android.text.TextWatcher;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import com.linote.diffstudio.core.Json;
import com.linote.diffstudio.core.Ota;
import com.linote.diffstudio.core.OtaException;
import com.linote.diffstudio.core.OtaPackage;
import com.linote.diffstudio.core.OtaRuntime;
import com.linote.diffstudio.core.Py;
import com.linote.diffstudio.core.Release;
import com.linote.diffstudio.ssh.Remote;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.regex.Pattern;

public final class MainActivity extends Activity {
    private static final int PICK_OLD = 1, PICK_NEW = 2, PICK_PATCH = 3, SAVE_ZIP = 4, SAVE_OTA = 5;
    private static final String DEFAULT_E5 = "192.168.9.1", DEFAULT_MU300 = "192.168.77.1";

    // ---------------------------------------------------------------- state (survives activity re-creation)
    static final class ModeState {
        String error = "", notice = "";
    }

    static final class St {
        String saveName = ""; // full file name offered in the last save dialog
        boolean about; // the About page is shown instead of the two tool pages
        int mode = 0; // 0 = Diff Studio, 1 = OpenWrt Updater
        boolean english, dark;
        boolean busy, monitoring;
        String progress = "";
        // studio
        Uri oldUri, newUri;
        String oldName = "", newName = "";
        Uri analyzedOld, analyzedNew;
        OtaPackage.Analysis analysis;
        boolean showFiles;
        final ModeState studio = new ModeState();
        // updater
        File patchFile;
        String patchName = "";
        Map<String, Object> manifest;
        Map<String, Object> review;
        boolean canReboot;
        boolean autoReboot = true;
        String host = DEFAULT_E5, password = "";
        final ModeState updater = new ModeState();
        Remote remote;
    }

    private static St S;
    private static MainActivity live; // background callbacks always update the visible instance
    private static final ExecutorService WORK = Executors.newSingleThreadExecutor();
    private final Handler ui = new Handler(Looper.getMainLooper());
    private SharedPreferences prefs;

    // views
    private LinearLayout card2, messages;
    private final List<View> lockable = new ArrayList<>();
    private Button analyzeBtn, connectBtn, statusBtn;
    private EditText hostEdit, pwEdit;
    private TextView progressView;
    private long lastProgress;
    private final Runnable pollTask = this::poll;

    // palette
    private int cBg, cFg, cCard, cMuted, cBorder, cPrimary, cPrimaryFg, cErr, cErrBg, cNoticeBg;

    // ---------------------------------------------------------------- lifecycle
    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        live = this;
        prefs = getSharedPreferences("ui", MODE_PRIVATE);
        if (S == null) {
            S = new St();
            S.english = "en".equals(prefs.getString("language", ""));
            int night = getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK;
            S.dark = prefs.contains("dark") ? prefs.getBoolean("dark", false) : night == Configuration.UI_MODE_NIGHT_YES;
            S.mode = prefs.getInt("mode", 0);
            S.remote = new Remote(getFilesDir(), d -> { if (live != null) live.onRemoteProgress(d); }, (h, p, t) -> AndroidIo.connect(getApplicationContext(), h, p, t));
        }
        fullRender();
        handleViewIntent(getIntent());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        handleViewIntent(intent);
    }

    private void handleViewIntent(Intent intent) {
        if (intent == null || !Intent.ACTION_VIEW.equals(intent.getAction()) || intent.getData() == null) return;
        Uri uri = intent.getData();
        intent.setData(null);
        String name = AndroidIo.displayName(this, uri);
        if (Pattern.compile("\\.ota$", Pattern.CASE_INSENSITIVE).matcher(name).find()) {
            S.mode = 1;
            fullRender();
            choose("patch", uri, name);
        } else if (Pattern.compile("\\.zip$", Pattern.CASE_INSENSITIVE).matcher(name).find()) {
            S.mode = 0;
            choose(S.oldUri == null ? "old" : "new", uri, name);
        }
    }

    @Override
    public void onConfigurationChanged(Configuration c) {
        super.onConfigurationChanged(c);
        fullRender();
    }

    private String n(String zh, String en) {
        return S.english ? en : zh;
    }

    private ModeState ms(int mode) {
        return mode == 0 ? S.studio : S.updater;
    }

    // ---------------------------------------------------------------- palette & widgets
    private static int hsl(float h, float s, float l) {
        s /= 100f;
        l /= 100f;
        float c = (1 - Math.abs(2 * l - 1)) * s, x = c * (1 - Math.abs((h / 60f) % 2 - 1)), m = l - c / 2;
        float r, g, b;
        if (h < 60) { r = c; g = x; b = 0; } else if (h < 120) { r = x; g = c; b = 0; } else if (h < 180) { r = 0; g = c; b = x; }
        else if (h < 240) { r = 0; g = x; b = c; } else if (h < 300) { r = x; g = 0; b = c; } else { r = c; g = 0; b = x; }
        return Color.rgb(Math.round((r + m) * 255), Math.round((g + m) * 255), Math.round((b + m) * 255));
    }

    private static int mix(int a, int b, float t) {
        return Color.rgb(Math.round(Color.red(a) * (1 - t) + Color.red(b) * t), Math.round(Color.green(a) * (1 - t) + Color.green(b) * t),
                Math.round(Color.blue(a) * (1 - t) + Color.blue(b) * t));
    }

    private void palette() {
        if (S.dark) {
            cBg = hsl(222, 25, 9); cFg = hsl(210, 20, 94); cCard = hsl(222, 22, 12); cMuted = hsl(215, 15, 68);
            cBorder = hsl(220, 18, 26); cPrimary = hsl(170, 59, 59); cPrimaryFg = hsl(222, 25, 9);
            cErr = Color.parseColor("#ffb4ab"); cErrBg = mix(cCard, hsl(0, 68, 42), 0.22f);
        } else {
            cBg = hsl(210, 20, 98); cFg = hsl(222, 30, 14); cCard = Color.WHITE; cMuted = hsl(215, 14, 40);
            cBorder = hsl(214, 20, 86); cPrimary = hsl(173, 80, 25); cPrimaryFg = Color.WHITE;
            cErr = hsl(0, 70, 40); cErrBg = mix(Color.WHITE, hsl(0, 70, 40), 0.08f);
        }
        cNoticeBg = mix(cCard, cPrimary, S.dark ? 0.14f : 0.07f);
    }

    private int dp(float v) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics()));
    }

    private GradientDrawable round(int fill, int stroke, float radius) {
        GradientDrawable g = new GradientDrawable();
        g.setColor(fill);
        g.setCornerRadius(dp(radius));
        if (stroke != 0) g.setStroke(dp(1), stroke);
        return g;
    }

    private TextView text(CharSequence s, float sp, int color, boolean bold) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setTextColor(color);
        if (bold) t.setTypeface(Typeface.DEFAULT_BOLD);
        t.setLineSpacing(0, 1.15f);
        return t;
    }

    private LinearLayout.LayoutParams lp(int w, int h, int top) {
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(w, h);
        p.topMargin = dp(top);
        return p;
    }

    private LinearLayout col() {
        LinearLayout l = new LinearLayout(this);
        l.setOrientation(LinearLayout.VERTICAL);
        return l;
    }

    private LinearLayout row() {
        LinearLayout l = new LinearLayout(this);
        l.setOrientation(LinearLayout.HORIZONTAL);
        l.setGravity(Gravity.CENTER_VERTICAL);
        return l;
    }

    private Button button(String label, boolean primary) {
        Button b = new Button(this);
        b.setAllCaps(false);
        b.setText(label);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        b.setStateListAnimator(null);
        b.setMinHeight(dp(46));
        b.setPadding(dp(14), 0, dp(14), 0);
        styleButton(b, primary);
        return b;
    }

    private void styleButton(Button b, boolean primary) {
        boolean on = b.isEnabled();
        if (primary) {
            b.setBackground(round(on ? cPrimary : mix(cCard, cPrimary, 0.35f), 0, 10));
            b.setTextColor(on ? cPrimaryFg : mix(cPrimaryFg, cPrimary, 0.4f));
        } else {
            b.setBackground(round(on ? cCard : mix(cCard, cBorder, 0.4f), cBorder, 10));
            b.setTextColor(on ? cFg : cMuted);
        }
        b.setTag(primary);
    }

    private void setEnabled(View v, boolean on) {
        v.setEnabled(on);
        if (v instanceof Button) styleButton((Button) v, Boolean.TRUE.equals(v.getTag()));
        v.setAlpha(on || v instanceof Button ? 1f : 0.55f);
    }

    private LinearLayout card() {
        LinearLayout c = col();
        c.setBackground(round(cCard, cBorder, 14));
        c.setPadding(dp(16), dp(16), dp(16), dp(18));
        c.setElevation(dp(1));
        return c;
    }

    private View heading(String number, String title) {
        LinearLayout r = row();
        TextView num = text(number, 13, cPrimaryFg, true);
        num.setGravity(Gravity.CENTER);
        num.setBackground(round(cPrimary, 0, 12));
        r.addView(num, new LinearLayout.LayoutParams(dp(24), dp(24)));
        TextView t = text(title, 17, cFg, true);
        t.setPadding(dp(10), 0, 0, 0);
        r.addView(t);
        return r;
    }

    private TextView label(String s) {
        TextView t = text(s, 13, cMuted, true);
        t.setLayoutParams(lp(-1, -2, 14));
        return t;
    }

    private Button picker(String value, String placeholder, Runnable onClick) {
        Button b = new Button(this);
        b.setAllCaps(false);
        b.setGravity(Gravity.CENTER_VERTICAL | Gravity.START);
        b.setStateListAnimator(null);
        b.setText((value.isEmpty() ? placeholder : value) + "");
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        b.setSingleLine(false);
        b.setMaxLines(3);
        b.setMinHeight(dp(52));
        b.setPadding(dp(14), dp(10), dp(14), dp(10));
        b.setTag(Boolean.FALSE);
        b.setOnClickListener(v -> onClick.run());
        b.setLayoutParams(lp(-1, -2, 6));
        GradientDrawable g = round(mix(cCard, cBg, 0.6f), cBorder, 10);
        b.setBackground(g);
        b.setTextColor(value.isEmpty() ? cMuted : cFg);
        b.setCompoundDrawablePadding(dp(8));
        return b;
    }

    private EditText edit(EditText reuse, String value, boolean password) {
        EditText e = reuse;
        if (e == null) {
            e = new EditText(this);
            e.setSingleLine(true);
            e.setText(value);
            e.setInputType(password ? InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD
                    : InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
            if (Build.VERSION.SDK_INT >= 26) e.setImportantForAutofill(password ? View.IMPORTANT_FOR_AUTOFILL_NO : View.IMPORTANT_FOR_AUTOFILL_AUTO);
        }
        if (e.getParent() != null) ((ViewGroup) e.getParent()).removeView(e);
        e.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        e.setTextColor(cFg);
        e.setHintTextColor(cMuted);
        e.setBackground(round(mix(cCard, cBg, 0.6f), cBorder, 10));
        e.setPadding(dp(14), dp(12), dp(14), dp(12));
        e.setLayoutParams(lp(-1, -2, 6));
        return e;
    }

    // ---------------------------------------------------------------- rendering
    private void fullRender() {
        palette();
        lockable.clear();
        getWindow().getDecorView().setBackgroundColor(cBg);
        if (Build.VERSION.SDK_INT < 35) {
            getWindow().setStatusBarColor(cBg);
            getWindow().setNavigationBarColor(cBg);
        }
        int flags = 0;
        if (!S.dark) flags |= View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR;
        getWindow().getDecorView().setSystemUiVisibility(flags);
        if (Build.VERSION.SDK_INT >= 30 && getWindow().getInsetsController() != null) {
            int light = android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS | android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
            getWindow().getInsetsController().setSystemBarsAppearance(S.dark ? 0 : light, light);
        }

        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        LinearLayout rootCol = col();
        rootCol.setPadding(dp(16), dp(12), dp(16), dp(24));
        scroll.addView(rootCol, new FrameLayout.LayoutParams(-1, -2));
        FrameLayout frame = new FrameLayout(this);
        frame.addView(scroll, new FrameLayout.LayoutParams(-1, -1));
        frame.setOnApplyWindowInsetsListener((v, insets) -> {
            int l, t, r, b;
            if (Build.VERSION.SDK_INT >= 30) {
                android.graphics.Insets i = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.ime() | WindowInsets.Type.displayCutout());
                l = i.left; t = i.top; r = i.right; b = i.bottom;
            } else {
                l = insets.getSystemWindowInsetLeft(); t = insets.getSystemWindowInsetTop();
                r = insets.getSystemWindowInsetRight(); b = insets.getSystemWindowInsetBottom();
            }
            v.setPadding(l, t, r, b);
            return insets;
        });

        // header
        LinearLayout header = row();
        TextView icon = text(S.mode == 0 ? "Δ" : "↻", 20, cPrimaryFg, true);
        icon.setGravity(Gravity.CENTER);
        icon.setBackground(round(cPrimary, 0, 10));
        header.addView(icon, new LinearLayout.LayoutParams(dp(40), dp(40)));
        LinearLayout brand = col();
        brand.setPadding(dp(10), 0, 0, 0);
        brand.addView(text(S.mode == 0 ? "OpenWrt Diff Studio" : "OpenWrt Updater", 16, cFg, true));
        brand.addView(text(n("保留数据 · 只更新变更文件", "Keep your data · Update changed files"), 12, cMuted, false));
        header.addView(brand, new LinearLayout.LayoutParams(0, -2, 1));
        Button lang = button(S.english ? "中文" : "English", false);
        lang.setMinWidth(0);
        lang.setMinimumWidth(0);
        lang.setOnClickListener(v -> {
            S.english = !S.english;
            prefs.edit().putString("language", S.english ? "en" : "zh").apply();
            fullRender();
        });
        lockable.add(lang);
        header.addView(lang, new LinearLayout.LayoutParams(-2, dp(40)));
        Button about = button(S.about ? "✕" : "ⓘ", false);
        about.setMinWidth(0);
        about.setMinimumWidth(0);
        about.setContentDescription(S.about ? n("关闭关于页", "Close About") : n("关于", "About"));
        about.setOnClickListener(v -> {
            S.about = !S.about;
            fullRender();
        });
        LinearLayout.LayoutParams ap = new LinearLayout.LayoutParams(dp(44), dp(40));
        ap.leftMargin = dp(6);
        header.addView(about, ap);
        Button theme = button(S.dark ? "☀" : "☾", false);
        theme.setMinWidth(0);
        theme.setMinimumWidth(0);
        theme.setContentDescription("Theme");
        theme.setOnClickListener(v -> {
            S.dark = !S.dark;
            prefs.edit().putBoolean("dark", S.dark).apply();
            fullRender();
        });
        LinearLayout.LayoutParams tp = new LinearLayout.LayoutParams(dp(44), dp(40));
        tp.leftMargin = dp(6);
        header.addView(theme, tp);
        rootCol.addView(header);

        if (S.about) {
            buildAbout(rootCol);
            card2 = null; // render() is idle while the About page is shown
            setContentView(frame);
            frame.requestApplyInsets();
            updateEnabled();
            return;
        }

        // mode switch (two windows of the desktop app: diff.html / ota.html)
        LinearLayout tabs = row();
        tabs.setBackground(round(mix(cCard, cBorder, 0.35f), cBorder, 12));
        tabs.setPadding(dp(4), dp(4), dp(4), dp(4));
        String[] names = {n("生成差异包", "Create patch"), n("更新设备", "Update device")};
        for (int i = 0; i < 2; i++) {
            final int m = i;
            Button t = new Button(this);
            t.setAllCaps(false);
            t.setStateListAnimator(null);
            t.setText(names[i]);
            t.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
            boolean sel = S.mode == i;
            t.setBackground(sel ? round(cCard, cBorder, 9) : round(Color.TRANSPARENT, 0, 9));
            t.setTextColor(sel ? cFg : cMuted);
            t.setTypeface(sel ? Typeface.DEFAULT_BOLD : Typeface.DEFAULT);
            t.setOnClickListener(v -> {
                if (S.mode != m) {
                    S.mode = m;
                    prefs.edit().putInt("mode", m).apply();
                    fullRender();
                }
            });
            tabs.addView(t, new LinearLayout.LayoutParams(0, dp(40), 1));
        }
        tabs.setLayoutParams(lp(-1, -2, 14));
        rootCol.addView(tabs);

        // intro
        TextView eyebrow = text(S.mode == 0 ? "RELEASE TO PATCH" : "DIFFERENTIAL SYSTEM UPDATE", 12, cPrimary, true);
        eyebrow.setLetterSpacing(0.12f);
        eyebrow.setLayoutParams(lp(-1, -2, 20));
        rootCol.addView(eyebrow);
        TextView h1 = text(S.mode == 0 ? n("把两版发行包，变成一次轻量更新", "Two releases. One compact update.")
                : n("更新系统，留下你的设置", "Update the system. Keep your setup."), 25, cFg, true);
        h1.setLayoutParams(lp(-1, -2, 6));
        rootCol.addView(h1);
        TextView intro = text(S.mode == 0
                ? n("点击选择旧版和新版完整 ZIP，分别放入对应框。相同内容只保存一份。", "Select the old and new full ZIPs for their respective boxes. Identical content is stored once.")
                : n("导入可信差异包，连接正在运行 OpenWrt 的设备，先检查再应用。", "Import a trusted patch and connect to a running OpenWrt device. Review before applying."),
                15, cMuted, false);
        intro.setLayoutParams(lp(-1, -2, 8));
        rootCol.addView(intro);

        // card 1
        LinearLayout c1 = card();
        c1.setLayoutParams(lp(-1, -2, 18));
        c1.addView(heading("1", S.mode == 0 ? n("选择发行版本", "Select releases") : n("选择补丁与设备", "Select patch and device")));
        if (S.mode == 0) {
            c1.addView(label(n("旧版完整包", "Old full release")));
            Button oldP = picker(S.oldName, n("选择 ZIP 文件", "Select ZIP file"), () -> pick(PICK_OLD));
            lockable.add(oldP);
            c1.addView(oldP);
            TextView arrow = text("↓", 18, cMuted, false);
            arrow.setGravity(Gravity.CENTER);
            arrow.setLayoutParams(lp(-1, -2, 6));
            c1.addView(arrow);
            c1.addView(label(n("新版完整包", "New full release")));
            Button newP = picker(S.newName, n("选择 ZIP 文件", "Select ZIP file"), () -> pick(PICK_NEW));
            lockable.add(newP);
            c1.addView(newP);
            analyzeBtn = button(n("分析差异", "Analyze changes"), true);
            analyzeBtn.setLayoutParams(lp(-1, dp(48), 18));
            analyzeBtn.setOnClickListener(v -> analyze());
            c1.addView(analyzeBtn);
        } else {
            Button patchP = picker(S.patchName, n("选择 .ota 差异包", "Select .ota patch"), () -> pick(PICK_PATCH));
            patchP.setLayoutParams(lp(-1, -2, 14));
            lockable.add(patchP);
            c1.addView(patchP);
            c1.addView(label(n("设备管理地址", "Device management address")));
            boolean fresh = hostEdit == null;
            hostEdit = edit(hostEdit, S.host, false);
            c1.addView(hostEdit);
            c1.addView(label("SSH root " + n("密码", "password")));
            boolean freshPw = pwEdit == null;
            pwEdit = edit(pwEdit, S.password, true);
            c1.addView(pwEdit);
            if (fresh) hostEdit.addTextChangedListener(new Watcher(true));
            if (freshPw) pwEdit.addTextChangedListener(new Watcher(false));
            lockable.add(hostEdit);
            lockable.add(pwEdit);
            connectBtn = button(n("连接并检查", "Connect and review"), true);
            connectBtn.setLayoutParams(lp(-1, dp(48), 18));
            connectBtn.setOnClickListener(v -> probe());
            c1.addView(connectBtn);
            statusBtn = button(n("重新检查设备状态", "Check device status"), false);
            statusBtn.setLayoutParams(lp(-1, dp(48), 10));
            statusBtn.setOnClickListener(v -> checkStatus());
            c1.addView(statusBtn);
        }
        rootCol.addView(c1);

        card2 = card();
        card2.setLayoutParams(lp(-1, -2, 16));
        rootCol.addView(card2);
        messages = col();
        rootCol.addView(messages, lp(-1, -2, 4));

        TextView footer = text("ⓘ  " + n("保留配置、额外插件和用户数据。系统变更写入前保留恢复副本，内核和模块可一同更新。仅导入可信来源的补丁。",
                "Settings, extra packages and user data are retained. Recovery copies precede writes. Kernel and modules can update together. Import trusted patches only."), 13, cMuted, false);
        footer.setLayoutParams(lp(-1, -2, 22));
        rootCol.addView(footer);
        setContentView(frame);
        frame.requestApplyInsets();
        render();
    }

    // ---------------------------------------------------------------- About page
    @Override
    @SuppressWarnings("deprecation")
    public void onBackPressed() {
        if (S != null && S.about) {
            S.about = false;
            fullRender();
            return;
        }
        super.onBackPressed();
    }

    private String versionName() {
        try {
            return getPackageManager().getPackageInfo(getPackageName(), 0).versionName;
        } catch (Exception e) {
            return "";
        }
    }

    private void aboutSection(LinearLayout parent, String title, String[][] items, boolean numbered) {
        LinearLayout c = card();
        c.setLayoutParams(lp(-1, -2, 14));
        c.addView(text(title, 17, cFg, true));
        for (String[] item : items) {
            if (item.length == 1) { // sub heading
                TextView h = text(item[0], 14, cPrimary, true);
                h.setLayoutParams(lp(-1, -2, 14));
                c.addView(h);
                continue;
            }
            LinearLayout r = new LinearLayout(this);
            r.setOrientation(LinearLayout.HORIZONTAL);
            r.setLayoutParams(lp(-1, -2, 8));
            TextView mark = text(item[0], 14, numbered ? cPrimary : cMuted, numbered);
            mark.setMinWidth(dp(22));
            r.addView(mark, new LinearLayout.LayoutParams(-2, -2));
            r.addView(text(item[1], 14, cFg, false), new LinearLayout.LayoutParams(0, -2, 1));
            c.addView(r);
        }
        parent.addView(c);
    }

    private void openLink(String url) {
        try {
            startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url)));
        } catch (ActivityNotFoundException e) {
            Toast.makeText(this, n("没有可打开网页的应用", "No app can open web links"), Toast.LENGTH_SHORT).show();
        }
    }

    private LinearLayout friendLink(int icon, String title, String url, boolean tint) {
        LinearLayout r = row();
        r.setPadding(dp(5), dp(3), dp(5), dp(3));
        r.setClickable(true);
        r.setFocusable(true);
        r.setContentDescription(title + n("，打开链接", ", open link"));
        r.setOnClickListener(v -> openLink(url));
        ImageView iv = new ImageView(this);
        iv.setImageResource(icon);
        iv.setScaleType(ImageView.ScaleType.FIT_CENTER);
        if (tint) iv.setImageTintList(ColorStateList.valueOf(cFg));
        iv.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        LinearLayout.LayoutParams ip = new LinearLayout.LayoutParams(dp(22), dp(22));
        ip.setMarginEnd(dp(6));
        r.addView(iv, ip);
        r.addView(text(title, 13, cFg, true), new LinearLayout.LayoutParams(-2, -2));
        r.setLayoutParams(new LinearLayout.LayoutParams(-2, dp(34)));
        return r;
    }

    private void buildAbout(LinearLayout root) {
        Button back = button("‹  " + n("返回", "Back"), false);
        back.setMinWidth(0);
        back.setMinimumWidth(0);
        back.setOnClickListener(v -> {
            S.about = false;
            fullRender();
        });
        LinearLayout.LayoutParams bp = new LinearLayout.LayoutParams(-2, dp(40));
        bp.topMargin = dp(14);
        root.addView(back, bp);

        // app card
        LinearLayout info = card();
        info.setLayoutParams(lp(-1, -2, 14));
        info.setGravity(Gravity.CENTER_HORIZONTAL);
        ImageView logo = new ImageView(this);
        logo.setImageResource(R.mipmap.ic_launcher);
        info.addView(logo, new LinearLayout.LayoutParams(dp(64), dp(64)));
        TextView name = text("OpenWrt Diff Studio", 19, cFg, true);
        name.setGravity(Gravity.CENTER);
        name.setLayoutParams(lp(-1, -2, 8));
        info.addView(name);
        TextView ver = text(n("安卓版 ", "Android ") + versionName(), 13, cMuted, false);
        ver.setGravity(Gravity.CENTER);
        info.addView(ver);
        TextView desc = text(n("比较两版 OpenWrt 完整发行包，生成只包含变更文件的差异包，并通过 SSH 直接更新设备。保留配置、额外插件和用户数据。",
                "Compare two full OpenWrt releases, build a patch with only the changed files, and update the device directly over SSH. Settings, extra packages and user data are kept."), 14, cFg, false);
        desc.setGravity(Gravity.CENTER);
        desc.setLayoutParams(lp(-1, -2, 10));
        info.addView(desc);
        root.addView(info);

        aboutSection(root, n("使用说明", "How to use"), new String[][]{
                {n("生成差异包", "Create patch")},
                {"1", n("在“生成差异包”页分别选择旧版（设备当前运行的版本）和新版完整 ZIP 发行包。支持 E5，以及 MU300 / F50 / V50 / U30Air。",
                        "On Create patch, select the old full release ZIP (the version the device runs now) and the new one. E5 and MU300 / F50 / V50 / U30Air are supported.")},
                {"2", n("点击“分析差异”，查看目标设备、版本变化、文件变更和载荷大小；不能生成时会列出原因。",
                        "Tap Analyze to review the target device, version change, changed files and payload size. Blocking reasons are listed if a patch cannot be made.")},
                {"3", n("点击“导出差异包”保存完整更新包 ZIP（含 update.ota、电脑端更新器和说明），或点击“仅导出 .ota 文件”。",
                        "Tap Export patch to save the complete update ZIP (update.ota, desktop updater and README), or Export .ota only.")},
                {n("更新设备", "Update device")},
                {"1", n("手机连接设备的 Wi-Fi 或 USB 网络共享，在“更新设备”页选择 .ota 差异包。也可以在文件管理器里用本应用直接打开 .ota。",
                        "Connect the phone to the device's Wi-Fi or USB tethering and select the .ota patch on Update device. You can also open an .ota with this app from a file manager.")},
                {"2", n("填写设备管理地址（E5 默认 192.168.9.1，MU300 默认 192.168.77.1，也可写成 地址:端口）和 root 密码。",
                        "Enter the management address (E5 192.168.9.1, MU300 192.168.77.1 by default; host:port also works) and the root password.")},
                {"3", n("点击“连接并检查”，确认空间、本地修改、依赖和版本检查都通过后，再点击“确认应用此补丁”。可勾选“更新完成后自动重启”。",
                        "Tap Connect and review. When space, local changes, dependencies and version all pass, tap Apply reviewed patch. Optionally enable automatic reboot.")},
                {"4", n("更新过程中 App 会自动显示进度；也可以随时点击“重新检查设备状态”。完成后按提示重启设备。",
                        "Progress is shown automatically; you can also tap Check device status at any time. Reboot the device when prompted.")},
        }, true);

        aboutSection(root, n("注意事项", "Important notes"), new String[][]{
                {"•", n("只导入和应用可信来源的补丁。补丁会以 root 权限写入系统文件。",
                        "Only import and apply patches from trusted sources. Patches write system files as root.")},
                {"•", n("旧版必须和设备当前运行的版本一致。检查未通过时不要强行更新。",
                        "The old release must match what the device runs now. Do not force an update when the review fails.")},
                {"•", n("更新期间保持设备通电，不要拔电或手动重启。手机可以锁屏或切到后台，设备端会独立完成写入。",
                        "Keep the device powered during the update and do not unplug or reboot it. The phone may lock or switch apps; the device finishes on its own.")},
                {"•", n("写入前设备会保留恢复副本，失败时自动回滚；重要配置仍建议先在设备网页备份。",
                        "The device keeps recovery copies before writing and rolls back on failure; still back up important settings in the device web UI first.")},
                {"•", n("分析 E5 发行包需要临时解压根文件系统镜像，请确保手机有足够的剩余空间（通常几百 MB 以上）。",
                        "Analyzing an E5 release temporarily extracts the root filesystem image; keep enough free storage (usually several hundred MB or more).")},
                {"•", n("设备 Wi-Fi 提示“无互联网”时请保持连接，App 会自动通过能到达设备的网络连接。",
                        "If the device Wi-Fi reports no internet, stay connected; the app automatically uses the network that reaches the device.")},
                {"•", n("检查和应用之间会核对设备身份；中途换了设备或设备重置后，需要重新检查。",
                        "The device identity is verified between review and apply; review again after switching or resetting the device.")},
                {"•", n("保存时如果文件名显示被截短，直接保存即可，导出完成后会自动恢复完整文件名和扩展名。",
                        "If the save dialog shortens the file name, just save; the full name and extension are restored after export.")},
                {"•", n("导出的补丁与电脑版格式相同，也可以用电脑端更新器或在设备网页“系统 > 系统补丁”中导入。",
                        "Exported patches use the desktop format and can also be applied with the desktop updater or in the device web UI (System > System patches).")},
        }, false);

        // footer: friend links, as in Lino迷你输入法
        LinearLayout title = row();
        LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(-1, dp(24));
        tlp.topMargin = dp(24);
        tlp.bottomMargin = dp(5);
        root.addView(title, tlp);
        View left = new View(this);
        left.setBackgroundColor(cBorder);
        LinearLayout.LayoutParams llp = new LinearLayout.LayoutParams(0, dp(1), 1f);
        llp.setMarginEnd(dp(10));
        title.addView(left, llp);
        TextView fl = text(n("友情链接", "Links"), 13, cMuted, false);
        fl.setGravity(Gravity.CENTER);
        title.addView(fl, new LinearLayout.LayoutParams(-2, -1));
        View right = new View(this);
        right.setBackgroundColor(cBorder);
        LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(0, dp(1), 1f);
        rlp.setMarginStart(dp(10));
        title.addView(right, rlp);

        LinearLayout links = row();
        links.setGravity(Gravity.CENTER);
        links.addView(friendLink(R.drawable.github_invertocat, n("GitHub 主页", "GitHub"), "https://github.com/linote99", true));
        links.addView(new View(this), new LinearLayout.LayoutParams(dp(16), 1));
        links.addView(friendLink(R.drawable.linote_logo, n("Lino 笔记", "Lino Notes"), "https://www.linote.top/", false));
        LinearLayout.LayoutParams lkp = new LinearLayout.LayoutParams(-1, -2);
        lkp.topMargin = dp(2);
        root.addView(links, lkp);
    }

    private final class Watcher implements TextWatcher {
        final boolean host;

        Watcher(boolean host) { this.host = host; }

        @Override public void beforeTextChanged(CharSequence s, int a, int b, int c) { }
        @Override public void onTextChanged(CharSequence s, int a, int b, int c) { }

        @Override
        public void afterTextChanged(Editable e) {
            String v = e.toString();
            if (host ? v.equals(S.host) : v.equals(S.password)) return;
            if (host) S.host = v;
            else S.password = v;
            boolean changed = S.review != null || S.canReboot;
            S.review = null;
            S.canReboot = false;
            if (changed) render();
            else updateEnabled();
        }
    }

    private boolean locked() {
        return S.busy || S.monitoring;
    }

    private void updateEnabled() {
        boolean y = locked();
        for (View v : lockable) setEnabled(v, !y);
        if (S.mode == 0 && analyzeBtn != null) setEnabled(analyzeBtn, !y && S.oldUri != null && S.newUri != null);
        if (S.mode == 1 && connectBtn != null) {
            setEnabled(connectBtn, !y && S.patchFile != null && !S.host.isEmpty());
            setEnabled(statusBtn, !S.busy && !S.host.isEmpty());
        }
        if (y) getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        else getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }

    private static String bytes(Object v) {
        long n = v instanceof Number ? Json.asLong(v) : 0;
        return n >= 1048576 ? String.format(Locale.ROOT, "%.1f MiB", n / 1048576.0) : String.format(Locale.ROOT, "%.1f KiB", n / 1024.0);
    }

    private static String s(Object v) {
        return v == null ? "" : String.valueOf(v);
    }

    private View stat(String value, String caption) {
        LinearLayout c = col();
        c.setBackground(round(mix(cCard, cBg, 0.6f), cBorder, 10));
        c.setPadding(dp(10), dp(10), dp(10), dp(10));
        TextView v = text(value, 17, cFg, true);
        c.addView(v);
        c.addView(text(caption, 12, cMuted, false));
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(0, -2, 1);
        p.leftMargin = dp(3);
        p.rightMargin = dp(3);
        c.setLayoutParams(p);
        return c;
    }

    private View details(String summary, String body) {
        LinearLayout box = col();
        TextView toggle = text("▸ " + summary, 13, cMuted, true);
        toggle.setPadding(0, dp(8), 0, dp(4));
        TextView pre = text(body, 12, cFg, false);
        pre.setTypeface(Typeface.MONOSPACE);
        pre.setTextIsSelectable(true);
        pre.setVisibility(View.GONE);
        pre.setBackground(round(mix(cCard, cBg, 0.7f), cBorder, 8));
        pre.setPadding(dp(10), dp(8), dp(10), dp(8));
        toggle.setOnClickListener(v -> {
            boolean open = pre.getVisibility() != View.VISIBLE;
            pre.setVisibility(open ? View.VISIBLE : View.GONE);
            toggle.setText((open ? "▾ " : "▸ ") + summary);
        });
        box.addView(toggle);
        box.addView(pre);
        return box;
    }

    private View errorBox(String raw) {
        ErrorExplain.Result r = ErrorExplain.explain(raw, S.english);
        LinearLayout box = col();
        box.setBackground(round(cErrBg, mix(cErrBg, cErr, 0.35f), 10));
        box.setPadding(dp(12), dp(10), dp(12), dp(10));
        box.addView(text("⚠  " + r.message, 14, cErr, false));
        box.addView(details(n("技术详情", "Technical details"), r.details));
        box.setLayoutParams(lp(-1, -2, 12));
        return box;
    }

    private View noticeBox(String msg, boolean spinner, String small) {
        LinearLayout box = row();
        box.setBackground(round(cNoticeBg, mix(cNoticeBg, cPrimary, 0.3f), 10));
        box.setPadding(dp(12), dp(10), dp(12), dp(10));
        if (spinner) {
            ProgressBar pb = new ProgressBar(this, null, android.R.attr.progressBarStyleSmall);
            if (Build.VERSION.SDK_INT >= 21) pb.setIndeterminateTintList(android.content.res.ColorStateList.valueOf(cPrimary));
            box.addView(pb, new LinearLayout.LayoutParams(dp(20), dp(20)));
        } else {
            box.addView(text("✓", 15, cPrimary, true));
        }
        LinearLayout c = col();
        c.setPadding(dp(10), 0, 0, 0);
        c.addView(text(msg, 14, cFg, false));
        if (small != null) {
            progressView = text(small, 12, cMuted, false);
            progressView.setTypeface(Typeface.MONOSPACE);
            c.addView(progressView);
        }
        box.addView(c, new LinearLayout.LayoutParams(0, -2, 1));
        box.setLayoutParams(lp(-1, -2, 12));
        return box;
    }

    @SuppressWarnings("unchecked")
    private void render() {
        if (live != null && live != this) {
            live.render();
            return;
        }
        if (card2 == null) return;
        if (hostEdit != null && !hostEdit.hasFocus() && !hostEdit.getText().toString().equals(S.host)) hostEdit.setText(S.host);
        updateEnabled();
        boolean y = locked();
        card2.removeAllViews();
        card2.addView(heading("2", n("检查并继续", "Review and continue")));
        OtaPackage.Analysis u = S.mode == 0 ? S.analysis : null;
        Map<String, Object> man = S.mode == 0 ? (u == null ? null : u.manifest) : S.manifest;
        if (man != null) {
            LinearLayout rel = col();
            rel.setBackground(round(mix(cCard, cBg, 0.6f), cBorder, 10));
            rel.setPadding(dp(12), dp(10), dp(12), dp(12));
            rel.setLayoutParams(lp(-1, -2, 14));
            LinearLayout top = row();
            top.addView(text(n("目标设备", "Target profile"), 12, cMuted, true), new LinearLayout.LayoutParams(0, -2, 1));
            top.addView(text(s(man.get("profile")), 14, cFg, true));
            rel.addView(top);
            TextView kr = text(s(man.get("kernel_release")), 12, cMuted, false);
            kr.setGravity(Gravity.END);
            rel.addView(kr, lp(-1, -2, 2));
            TextView ver = text(s(man.get("base_version")) + "\n→ " + s(man.get("target_version")), 14, cFg, false);
            ver.setTypeface(Typeface.MONOSPACE);
            ver.setLayoutParams(lp(-1, -2, 8));
            rel.addView(ver);
            card2.addView(rel);
        } else {
            TextView empty = text("◎\n" + n("选择文件后，在这里查看版本与兼容检查结果。", "Select files to review versions and compatibility here."), 14, cMuted, false);
            empty.setGravity(Gravity.CENTER);
            empty.setPadding(dp(8), dp(26), dp(8), dp(26));
            card2.addView(empty, lp(-1, -2, 8));
        }
        if (man != null && Json.truthy(man.get("boot"))) {
            card2.addView(noticeBox(n("包含内核与启动镜像更新，配套模块随系统差异一起更新；用户插件、配置和数据保留。",
                    "Includes kernel/boot update and matching module changes. User packages, settings and data are retained."), false, null));
        }
        if (u != null) {
            LinearLayout stats = row();
            stats.setLayoutParams(lp(-1, -2, 12));
            stats.addView(stat(String.valueOf(u.files), n("文件变更", "Changed files")));
            stats.addView(stat(bytes(u.payloadBytes), n("未压缩载荷", "Uncompressed payload")));
            stats.addView(stat(u.added + " / " + u.removed, n("新增 / 删除", "Added / removed")));
            card2.addView(stats);
            if (!u.blockers.isEmpty()) {
                LinearLayout box = col();
                box.setBackground(round(cErrBg, mix(cErrBg, cErr, 0.35f), 10));
                box.setPadding(dp(12), dp(10), dp(12), dp(10));
                box.setContentDescription(n("无法生成的原因", "Reasons export is unavailable"));
                for (String b : u.blockers) box.addView(text(ErrorExplain.explain(b, S.english).message, 14, cErr, false));
                box.addView(details(n("技术详情", "Technical details"), String.join("\n", u.blockers)));
                box.setLayoutParams(lp(-1, -2, 12));
                card2.addView(box);
            }
            List<Object> ops = (List<Object>) u.manifest.get("operations");
            StringBuilder sb = new StringBuilder();
            int shown = 0;
            for (Object o : ops) {
                Map<String, Object> op = (Map<String, Object>) o;
                if (shown == 4000) {
                    sb.append("… +").append(ops.size() - shown);
                    break;
                }
                String mark = op.get("before") != null ? (op.get("after") != null ? "~" : "−") : "+";
                sb.append(mark).append(' ').append(op.get("path")).append('\n');
                shown++;
            }
            card2.addView(details(n("查看文件清单", "View file list"), sb.toString().trim()));
            Button export = button(n("导出差异包", "Export patch"), true);
            export.setLayoutParams(lp(-1, dp(48), 14));
            setEnabled(export, !y && u.canExport);
            export.setOnClickListener(v -> save(SAVE_ZIP, u.suggestedName));
            card2.addView(export);
            Button exportOta = button(n("仅导出 .ota 文件", "Export .ota only"), false);
            exportOta.setLayoutParams(lp(-1, dp(46), 8));
            setEnabled(exportOta, !y && u.canExport);
            exportOta.setOnClickListener(v -> save(SAVE_OTA, u.suggestedName.replaceAll("(?i)\\.zip$", "") + ".ota"));
            card2.addView(exportOta);
        }
        Map<String, Object> j = S.mode == 1 ? S.review : null;
        if (j != null) {
            Map<String, Object> check = Json.map(j.get("check"));
            if (check == null) check = new java.util.LinkedHashMap<>();
            TextView space = text(n("所需空间 / 可用空间：", "Required / available: ") + bytes(check.get("required_bytes")) + " / " + bytes(check.get("free_bytes")), 14, cFg, false);
            space.setLayoutParams(lp(-1, -2, 14));
            card2.addView(space);
            List<String> conflicts = new ArrayList<>();
            for (String key : new String[]{"conflicts", "package_conflicts"}) {
                Object v = check.get(key);
                if (v instanceof List) for (Object x : (List<Object>) v) conflicts.add(String.valueOf(x));
            }
            if (!conflicts.isEmpty()) {
                TextView ce = text(n("本地文件或依赖冲突，未写入：", "Local file or dependency conflicts; nothing written: ") + String.join(", ", conflicts), 14, cErr, false);
                ce.setBackground(round(cErrBg, mix(cErrBg, cErr, 0.35f), 10));
                ce.setPadding(dp(12), dp(10), dp(12), dp(10));
                ce.setLayoutParams(lp(-1, -2, 10));
                card2.addView(ce);
            }
            CheckBox auto = new CheckBox(this);
            auto.setText(n("更新完成后自动重启", "Automatically reboot after updating"));
            auto.setTextColor(cFg);
            auto.setChecked(S.autoReboot);
            if (Build.VERSION.SDK_INT >= 21) auto.setButtonTintList(android.content.res.ColorStateList.valueOf(cPrimary));
            auto.setEnabled(!y);
            auto.setOnCheckedChangeListener((b, c) -> S.autoReboot = c);
            auto.setLayoutParams(lp(-1, -2, 12));
            card2.addView(auto);
            Button apply = button(n("确认应用此补丁", "Apply reviewed patch"), true);
            apply.setLayoutParams(lp(-1, dp(48), 10));
            setEnabled(apply, !y && Json.truthy(check.get("applicable")));
            apply.setOnClickListener(v -> apply());
            card2.addView(apply);
        }

        messages.removeAllViews();
        progressView = null;
        ModeState m = ms(S.mode);
        if (S.busy || S.monitoring) {
            messages.addView(noticeBox(S.monitoring ? n("设备正在写入，关闭本应用不会终止设备事务。", "Device is writing. Closing this app does not cancel its transaction.")
                    : n("正在处理，请稍候…", "Processing…"), true, S.progress));
        }
        if (!m.error.isEmpty()) messages.addView(errorBox(m.error));
        if (!m.notice.isEmpty()) messages.addView(noticeBox(m.notice, false, null));
        if (S.mode == 1 && S.canReboot) {
            Button rb = button("⏻  " + n("重启设备", "Reboot device"), false);
            rb.setLayoutParams(lp(-1, dp(48), 12));
            setEnabled(rb, !y);
            rb.setOnClickListener(v -> confirmReboot());
            messages.addView(rb);
        }
    }

    // ---------------------------------------------------------------- work plumbing
    interface Task {
        void run() throws Exception;
    }

    /** D(): one operation at a time, clears messages, reports the error string. */
    private void run(Task task) {
        final int mode = S.mode;
        ModeState m = ms(mode);
        S.busy = true;
        m.error = "";
        m.notice = "";
        S.progress = "";
        render();
        WorkService.start(this, n("正在处理，请稍候…", "Processing…"));
        WORK.execute(() -> {
            String err = null;
            try {
                task.run();
            } catch (Throwable t) {
                err = describe(t);
            }
            final String e = err;
            ui.post(() -> {
                S.busy = false;
                if (e != null) ms(mode).error = e;
                if (!S.monitoring) WorkService.stop(getApplicationContext());
                render();
            });
        });
    }

    static String describe(Throwable t) {
        if (t instanceof OtaException) return t.getMessage();
        Throwable c = t;
        if (c instanceof com.jcraft.jsch.JSchException && c.getCause() != null) c = c.getCause();
        String msg = c.getMessage() == null ? c.getClass().getSimpleName() : c.getMessage();
        if (c instanceof com.jcraft.jsch.JSchException) {
            if (msg.contains("Auth fail") || msg.contains("Auth cancel") || msg.contains("USERAUTH fail") || msg.contains("Too many authentication failures")) return "Authentication failed. (" + msg + ")";
            if (msg.contains("timeout")) return "Connection timed out (" + msg + ")";
            if (msg.contains("channel is not opened") || msg.contains("session is down")) return "Connection closed (" + msg + ")";
            return msg;
        }
        if (c instanceof java.net.UnknownHostException) return "Unable to connect: unknown host " + msg;
        if (c instanceof java.net.SocketTimeoutException) return "Connection timed out (" + msg + ")";
        if (c instanceof java.net.NoRouteToHostException) return "No route to host (" + msg + ")";
        if (c instanceof java.net.ConnectException) return "Unable to connect (" + msg + ")";
        if (c instanceof java.util.zip.ZipException) return "BadZipFile: " + msg;
        if (c instanceof java.io.EOFException) return "EOF: " + msg;
        if (c instanceof OutOfMemoryError) return "Insufficient memory: " + msg;
        if (c instanceof SecurityException) return "Permission denied: " + msg;
        return c.getClass().getSimpleName().replace("Exception", "Error") + ": " + msg;
    }

    private void onProgress(String stage, String path) {
        long now = System.nanoTime();
        if (now - lastProgress < 400_000_000L) return;
        lastProgress = now;
        String p = path == null || path.isEmpty() ? stage : path;
        ui.post(() -> setProgress(p));
    }

    private void onRemoteProgress(Map<String, Object> d) {
        if ("upload".equals(d.get("stage"))) {
            String p = "↑ " + bytes(d.get("done")) + " / " + bytes(d.get("total"));
            ui.post(() -> setProgress(p));
        }
    }

    private void setProgress(String p) {
        if (live != null && live != this) {
            live.setProgress(p);
            return;
        }
        S.progress = p;
        if (progressView != null) progressView.setText(p);
    }

    private OtaRuntime.SupportFiles support() {
        return name -> {
            try (InputStream in = getAssets().open("ota/" + name)) {
                return Py.readAll(in);
            }
        };
    }

    // ---------------------------------------------------------------- pickers
    private void pick(int code) {
        Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        i.addCategory(Intent.CATEGORY_OPENABLE);
        i.setType("*/*");
        if (code != PICK_PATCH) i.putExtra(Intent.EXTRA_MIME_TYPES, new String[]{"application/zip", "application/x-zip-compressed", "application/octet-stream", "*/*"});
        try {
            startActivityForResult(i, code);
        } catch (RuntimeException e) {
            ms(S.mode).error = describe(e);
            render();
        }
    }

    private void save(int code, String suggested) {
        Intent i = new Intent(Intent.ACTION_CREATE_DOCUMENT);
        i.addCategory(Intent.CATEGORY_OPENABLE);
        i.setType(code == SAVE_ZIP ? "application/zip" : "application/octet-stream");
        i.putExtra(Intent.EXTRA_TITLE, suggested);
        S.saveName = suggested;
        try {
            startActivityForResult(i, code);
        } catch (RuntimeException e) {
            ms(S.mode).error = describe(e);
            render();
        }
    }

    @Override
    protected void onActivityResult(int code, int result, Intent data) {
        super.onActivityResult(code, result, data);
        if (result != RESULT_OK || data == null || data.getData() == null) return;
        Uri uri = data.getData();
        int flags = Intent.FLAG_GRANT_READ_URI_PERMISSION | (code >= SAVE_ZIP ? Intent.FLAG_GRANT_WRITE_URI_PERMISSION : 0);
        try {
            getContentResolver().takePersistableUriPermission(uri, flags);
        } catch (RuntimeException ignored) {
            // not every provider offers persistable grants; the transient grant suffices for this session
        }
        if (code == SAVE_ZIP || code == SAVE_OTA) {
            export(uri, code == SAVE_ZIP, S.saveName);
            return;
        }
        String name = AndroidIo.displayName(this, uri);
        choose(code == PICK_OLD ? "old" : code == PICK_NEW ? "new" : "patch", uri, name);
    }

    /** ge(kind, path) */
    private void choose(String kind, Uri uri, String name) {
        Pattern want = Pattern.compile(kind.equals("patch") ? "\\.ota$" : "\\.zip$", Pattern.CASE_INSENSITIVE);
        ModeState m = ms(kind.equals("patch") ? 1 : 0);
        if (!want.matcher(name).find()) {
            m.error = kind.equals("patch") ? n("请选择 .ota 差异包。", "Select an .ota patch.") : n("请选择完整 ZIP 发行包。", "Select a full release ZIP.");
            fullRender();
            return;
        }
        m.error = "";
        S.review = null;
        S.analysis = null;
        m.notice = "";
        S.canReboot = false;
        if (kind.equals("old")) {
            S.oldUri = uri;
            S.oldName = name;
            fullRender();
        } else if (kind.equals("new")) {
            S.newUri = uri;
            S.newName = name;
            fullRender();
        } else {
            S.patchName = name;
            S.manifest = null;
            fullRender();
            run(() -> {
                File dir = new File(getFilesDir(), "patches");
                //noinspection ResultOfMethodCallIgnored
                dir.mkdirs();
                File[] old = dir.listFiles();
                if (old != null) for (File f : old) //noinspection ResultOfMethodCallIgnored
                    f.delete();
                String safe = name.replaceAll("[^A-Za-z0-9._-]", "_");
                File dest = new File(dir, safe.isEmpty() ? "update.ota" : safe);
                AndroidIo.copyToFile(this, uri, dest);
                Map<String, Object> manifest;
                try (Ota.Patch patch = new Ota.Patch(dest)) {
                    manifest = patch.manifest;
                }
                S.remote.selectPatch(dest);
                ui.post(() -> {
                    S.patchFile = dest;
                    S.manifest = manifest;
                    if (S.host.equals(DEFAULT_E5) || S.host.equals(DEFAULT_MU300)) {
                        S.host = "mu300".equals(manifest.get("family")) ? DEFAULT_MU300 : DEFAULT_E5;
                        if (hostEdit != null) hostEdit.setText(S.host);
                    }
                    render();
                });
            });
        }
    }

    // ---------------------------------------------------------------- Diff Studio commands
    private void analyze() {
        final Uri oldUri = S.oldUri, newUri = S.newUri;
        run(() -> {
            File scratch = AndroidIo.scratch(this);
            Release.Source a = AndroidIo.openRelease(this, oldUri, scratch);
            Release.Source b;
            try {
                b = AndroidIo.openRelease(this, newUri, scratch);
            } catch (IOException | RuntimeException e) {
                a.owner.close();
                throw e;
            }
            OtaPackage.Analysis r = OtaPackage.analyze(a, b, null, this::onProgress, support(), scratch);
            ui.post(() -> {
                S.analyzedOld = oldUri;
                S.analyzedNew = newUri;
                S.analysis = r;
            });
        });
    }

    private void export(Uri dest, boolean bundle, String intendedName) {
        final Uri oldUri = S.analyzedOld, newUri = S.analyzedNew;
        run(() -> {
            if (oldUri == null || newUri == null) throw new OtaException("Analyze the old and new release first");
            // vendor save dialogs may shorten the name and swap the extension (".bin"); restore it first
            final Uri target = AndroidIo.fixSavedName(this, dest, intendedName);
            File scratch = AndroidIo.scratch(this);
            File dir = new File(scratch, "export-" + System.nanoTime());
            if (!dir.mkdirs()) throw new OtaException("Cannot create temporary export directory");
            try {
                File patch = new File(dir, "update.ota");
                Release.Source a = AndroidIo.openRelease(this, oldUri, scratch);
                Release.Source b;
                try {
                    b = AndroidIo.openRelease(this, newUri, scratch);
                } catch (IOException | RuntimeException e) {
                    a.owner.close();
                    throw e;
                }
                OtaPackage.analyze(a, b, patch, this::onProgress, support(), scratch);
                File out = patch;
                if (bundle) {
                    out = new File(dir, "bundle.zip");
                    onProgress("bundle", "README.md");
                    com.linote.diffstudio.core.Bundle.export(patch, out, name -> getAssets().open("bundle/" + name));
                }
                AndroidIo.copyToUri(this, out, target);
                String shown = AndroidIo.displayName(this, target);
                String ext = bundle ? ".zip" : ".ota";
                boolean extOk = shown.toLowerCase(java.util.Locale.ROOT).endsWith(ext);
                ui.post(() -> ms(0).notice = n("已生成差异包：", "Patch saved: ") + shown
                        + (extOk ? "" : n("\n当前保存位置不允许修改文件名，请在文件管理器中把扩展名改为 " + ext + "。",
                        "\nThis location does not allow renaming; change the file extension to " + ext + " in your file manager.")));
            } finally {
                File[] left = dir.listFiles();
                if (left != null) for (File f : left) //noinspection ResultOfMethodCallIgnored
                    f.delete();
                //noinspection ResultOfMethodCallIgnored
                dir.delete();
            }
        });
    }

    // ---------------------------------------------------------------- updater commands
    private void probe() {
        final String host = S.host, pw = S.password;
        final File patch = S.patchFile;
        run(() -> {
            Map<String, Object> r = S.remote.probe(host, pw, patch);
            ui.post(() -> S.review = r);
        });
    }

    private void apply() {
        final Map<String, Object> j = S.review;
        final String host = S.host, pw = S.password;
        final boolean auto = S.autoReboot;
        run(() -> {
            S.remote.apply(host, pw, (String) j.get("token"), auto);
            ui.post(() -> {
                S.canReboot = false;
                S.monitoring = true;
                S.review = null;
                schedulePoll();
            });
        });
    }

    private void checkStatus() {
        final String host = S.host, pw = S.password;
        final File patch = S.patchFile;
        run(() -> {
            Map<String, Object> r = S.remote.status(host, pw, patch);
            ui.post(() -> {
                Map<String, Object> job = Json.map(r.get("job"));
                boolean running = job != null && "running".equals(job.get("status"));
                boolean was = S.monitoring;
                S.monitoring = running;
                handleStatus(r);
                if (running && !was) schedulePoll();
            });
        });
    }

    private void schedulePoll() {
        WorkService.start(this, n("设备正在写入，关闭本应用不会终止设备事务。", "Device is writing. Closing this app does not cancel its transaction."));
        ui.removeCallbacks(pollTask);
        ui.postDelayed(pollTask, 2000);
    }

    private void poll() {
        if (!S.monitoring) return;
        final String host = S.host, pw = S.password;
        final File patch = S.patchFile;
        WORK.execute(() -> {
            boolean again = true;
            try {
                Map<String, Object> r = S.remote.status(host, pw, patch);
                Map<String, Object> tx = Json.map(r.get("transaction"));
                Map<String, Object> job = Json.map(r.get("job"));
                if (tx != null) {
                    String p = s(tx.get("started")) + " / " + s(tx.get("total"));
                    ui.post(() -> setProgress(p));
                }
                if (job == null || !"running".equals(job.get("status"))) {
                    again = false;
                    ui.post(() -> {
                        S.monitoring = false;
                        if (!S.busy) WorkService.stop(getApplicationContext());
                        handleStatus(r);
                    });
                }
            } catch (Throwable t) {
                ui.post(() -> setProgress(n("连接中断；设备继续处理，可稍后重新检查状态。",
                        "Connection interrupted. The device continues processing; check status again later.")));
            } finally {
                if (again) ui.post(() -> {
                    ui.removeCallbacks(pollTask);
                    ui.postDelayed(pollTask, 2000);
                });
            }
        });
    }

    /** we(l): interpret a status result. */
    private void handleStatus(Map<String, Object> l) {
        ModeState m = S.updater;
        Map<String, Object> job = Json.map(l.get("job"));
        Map<String, Object> tx = Json.map(l.get("transaction"));
        Map<String, Object> reboot = Json.map(l.get("reboot"));
        Map<String, Object> activation = Json.map(l.get("activation"));
        String jobStatus = job == null ? null : Json.str(job.get("status"));
        String txStatus = tx == null ? "" : s(tx.get("status"));
        boolean c = "complete".equals(jobStatus) && ("complete".equals(txStatus) || "rolled_back".equals(txStatus));
        m.notice = "";
        m.error = "";
        S.canReboot = c;
        if ("failed".equals(jobStatus)) {
            Map<String, Object> res = Json.map(job.get("result"));
            String e = res == null ? null : Json.str(res.get("error"));
            m.error = e != null && !e.isEmpty() ? e : n("更新未完成，请检查设备事务状态。", "Update incomplete. Review device transaction status.");
            render();
            return;
        }
        if (reboot != null && "rebooting".equals(reboot.get("status"))) {
            S.canReboot = false;
            m.notice = n("更新完成，设备正在重启。稍后可重新检查设备状态。", "Update complete. The device is rebooting. Check its status again shortly.");
        } else if (reboot != null && Json.truthy(reboot.get("error"))) {
            m.error = n("更新已完成，重启失败，可点击下方按钮重试：", "Update completed, but reboot failed. Retry below: ") + s(reboot.get("error"));
        } else if (c) {
            m.notice = "rolled_back".equals(txStatus) ? n("回滚完成，可在此重启设备。", "Rollback complete. Reboot the device here.")
                    : n("更新完成，可在此直接重启设备使更新生效。", "Update complete. Reboot the device here to activate the update.");
        } else if (!"running".equals(jobStatus)) {
            Map<String, Object> identity = Json.map(l.get("identity"));
            m.notice = n("设备状态已读取。当前版本：", "Device status loaded. Current version: ") + (identity == null ? "" : s(identity.get("version")));
        }
        if (activation != null && "warning".equals(activation.get("status"))) {
            m.error = n("系统文件已更新，网页插件重载失败：", "System files are updated, but web plugin reload failed: ") + s(activation.get("error"));
        }
        render();
    }

    private void confirmReboot() {
        AlertDialog d = new AlertDialog.Builder(this, S.dark ? android.R.style.Theme_DeviceDefault_Dialog_Alert : android.R.style.Theme_DeviceDefault_Light_Dialog_Alert)
                .setTitle(n("重启设备？", "Reboot device?"))
                .setMessage(n("更新已完成。重启会短暂断开网络，配置和数据会保留。", "The update is complete. Rebooting briefly disconnects networking; settings and data are retained."))
                .setNegativeButton(n("取消", "Cancel"), null)
                .setPositiveButton(n("确认重启", "Confirm reboot"), (dlg, w) -> {
                    final String host = S.host, pw = S.password;
                    run(() -> {
                        S.remote.reboot(host, pw);
                        ui.post(() -> {
                            S.canReboot = false;
                            S.updater.notice = n("重启命令已发送，设备正在重新启动。", "Reboot requested. The device is restarting.");
                        });
                    });
                })
                .create();
        d.show();
    }

    @Override
    protected void onDestroy() {
        ui.removeCallbacks(pollTask);
        if (live == this) live = null;
        super.onDestroy();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (live != this) {
            live = this;
            render();
        }
        if (S.monitoring) {
            ui.removeCallbacks(pollTask);
            ui.postDelayed(pollTask, 500);
        }
    }
}
