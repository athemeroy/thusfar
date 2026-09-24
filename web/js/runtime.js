// The Android app serves this origin on the phone even when Android reports no internet.
export const standalone = /YeduStandalone\/1\b/.test(navigator.userAgent);
export const canReachLibrary = () => standalone || navigator.onLine;
