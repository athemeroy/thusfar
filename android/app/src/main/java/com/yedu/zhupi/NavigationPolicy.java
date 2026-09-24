package com.yedu.zhupi;

import java.net.URI;

/** Pure policy shared by native navigation and download handling. */
final class NavigationPolicy {
    private static volatile int localPort = -1;

    static void setLocalPort(int port) {
        if (port < 1 || port > 65535) throw new IllegalArgumentException("Invalid local port");
        localPort = port;
    }

    static String home() {
        if (localPort < 1) throw new IllegalStateException("Local server is not ready");
        return "http://127.0.0.1:" + localPort + "/";
    }

    private NavigationPolicy() { }

    static boolean sameOrigin(String address) {
        try {
            URI uri = URI.create(address);
            return localPort > 0 && "http".equalsIgnoreCase(uri.getScheme())
                    && "127.0.0.1".equals(uri.getHost())
                    && uri.getPort() == localPort && uri.getRawUserInfo() == null;
        } catch (IllegalArgumentException | NullPointerException e) {
            return false;
        }
    }

    static boolean downloadable(String address) {
        if (!sameOrigin(address)) return false;
        String path = URI.create(address).getPath();
        return path.matches("/api/books/[A-Za-z0-9_-]{1,64}/(?:export|notebook\\.md)");
    }

    static boolean handlesVolume(boolean reading, boolean enabled) {
        return reading && enabled;
    }
}
