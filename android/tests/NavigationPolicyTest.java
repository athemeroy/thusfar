package com.yedu.zhupi;

/** Host-JVM checks for the native credential and hardware-key boundaries. */
public final class NavigationPolicyTest {
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    public static void main(String[] args) {
        NavigationPolicy.setLocalPort(18770);
        String home = NavigationPolicy.home();
        check(NavigationPolicy.sameOrigin(home + "#/read/a"), "reader route");
        check(NavigationPolicy.downloadable(home + "api/books/test-book/export"), "export");
        check(NavigationPolicy.downloadable(home + "api/books/test-book/notebook.md"), "personal notebook export");
        for (String address : new String[]{
                "http://127.0.0.1:18771/api/books/a/export",
                "https://127.0.0.1:18770/api/books/a/export",
                "http://127.0.0.2:18770/api/books/a/export",
                "http://user@127.0.0.1:18770/api/books/a/export",
                "http://other.test:18770/api/books/a/export",
                "javascript:alert(1)", "file:///etc/passwd", null}) {
            check(!NavigationPolicy.sameOrigin(address), "reject external origin");
            check(!NavigationPolicy.downloadable(address), "never send cookie externally");
        }
        for (String path : new String[]{"api/books/a", "api/books/a/notebookXmd", "api/books/a/notebook.md/extra", "api/login", "download/../secrets.env", "download/%2fsecret.apk"})
            check(!NavigationPolicy.downloadable(home + path), "restrict download purpose");
        check(NavigationPolicy.handlesVolume(true, true), "paging enabled while reading");
        check(!NavigationPolicy.handlesVolume(true, false), "system volume restored when paging disabled");
        check(!NavigationPolicy.handlesVolume(false, true), "system volume on shelf");
        System.out.println("Native navigation/download/volume policy checks passed");
    }
}
