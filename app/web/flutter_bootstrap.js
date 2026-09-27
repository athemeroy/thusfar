{{flutter_js}}
{{flutter_build_config}}

// Flutter 3.47 emits an unregister-only service worker. Our own worker caches
// the public app shell; books and reading state stay in IndexedDB.
const appBase = new URL('.', document.baseURI);
_flutter.loader.load({
  config: {canvasKitBaseUrl: new URL('canvaskit/', appBase).href},
});

if ('serviceWorker' in navigator) {
  const hadController = Boolean(navigator.serviceWorker.controller);
  let updateDismissed = false;
  navigator.serviceWorker.addEventListener('controllerchange', () => {
    if (!hadController || updateDismissed || !navigator.serviceWorker.controller ||
        document.getElementById('thusfar-update-ready')) {
      return;
    }

    const notice = document.createElement('div');
    notice.id = 'thusfar-update-ready';
    notice.setAttribute('role', 'status');
    notice.setAttribute('aria-live', 'polite');
    notice.style.cssText =
      'position:fixed;right:16px;bottom:calc(16px + env(safe-area-inset-bottom, 0px));' +
      'z-index:2147483647;display:flex;align-items:center;flex-wrap:wrap;gap:12px;' +
      'max-width:calc(100vw - 32px);padding:12px 16px;border-radius:12px;' +
      'background:#292720;color:#fff;box-shadow:0 6px 24px #0004;' +
      'font:14px/1.4 system-ui,sans-serif';

    const message = document.createElement('span');
    message.textContent = '新版本已准备好';
    const refresh = document.createElement('button');
    refresh.type = 'button';
    refresh.textContent = '刷新页面';
    refresh.style.cssText =
      'border:0;border-radius:8px;padding:8px 12px;background:#f2ede2;' +
      'color:#292720;font:inherit;font-weight:600;cursor:pointer';
    refresh.addEventListener('click', () => window.location.reload());
    const dismiss = document.createElement('button');
    dismiss.type = 'button';
    dismiss.textContent = '稍后';
    dismiss.style.cssText =
      'border:1px solid #fff8;border-radius:8px;padding:8px 12px;' +
      'background:transparent;color:#fff;font:inherit;cursor:pointer';
    dismiss.addEventListener('click', () => {
      updateDismissed = true;
      notice.remove();
    });
    notice.append(message, refresh, dismiss);
    document.body.append(notice);
  });

  const registerOfflineShell = () => {
    navigator.serviceWorker.register(
      new URL('app_shell_sw.js', appBase),
      {scope: appBase.href, updateViaCache: 'none'},
    ).catch((error) => console.warn('Offline shell unavailable:', error));
  };
  if (document.readyState === 'complete') {
    registerOfflineShell();
  } else {
    window.addEventListener('load', registerOfflineShell, {once: true});
  }
}
