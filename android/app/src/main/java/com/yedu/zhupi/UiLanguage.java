package com.yedu.zhupi;

import android.content.Context;
import android.content.res.Configuration;

import java.util.Locale;

/** Native dialogs and processing notifications follow the language selected in the reader. */
final class UiLanguage {
    private static final String PREFERENCES = "yedu-language";
    private static final String SELECTED = "selected";

    private UiLanguage() { }

    static boolean supported(String code) {
        return "auto".equals(code) || "zh-CN".equals(code) || "en".equals(code)
                || "es".equals(code) || "fr".equals(code) || "de".equals(code)
                || "pt-BR".equals(code) || "ja".equals(code) || "ko".equals(code);
    }

    static void save(Context context, String code) {
        if (!supported(code)) return;
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit()
                .putString(SELECTED, code).commit();
    }

    static String preference(Context context) {
        String selected = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                .getString(SELECTED, "auto");
        return supported(selected) ? selected : "auto";
    }

    static String get(Context context, int resource) {
        String selected = preference(context);
        if ("auto".equals(selected)) return context.getString(resource);
        Configuration config = new Configuration(context.getResources().getConfiguration());
        config.setLocale(Locale.forLanguageTag(selected));
        return context.createConfigurationContext(config).getString(resource);
    }
}
