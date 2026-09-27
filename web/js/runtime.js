// The Android app serves this origin on the phone even when Android reports no internet.
export const standalone = /YeduStandalone\/1\b/.test(navigator.userAgent);
// A native desktop/local server can expose settings without becoming Android.
export const localSettings = standalone || globalThis.document?.querySelector?.('meta[name="yedu-local-settings"]')?.content === 'true';
export const canReachLibrary = () => standalone || navigator.onLine;
