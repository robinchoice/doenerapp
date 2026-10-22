// Shows pushes while the web app is in the background or closed.
// The image build fills in FIREBASE_WEB_KEY (see Dockerfile).
importScripts('https://www.gstatic.com/firebasejs/13.0.0/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/13.0.0/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: 'FIREBASE_WEB_KEY',
  projectId: 'doener-app-510118',
  messagingSenderId: '26724390514',
  appId: '1:26724390514:web:d8f8f2970f78702d3d54eb',
});

// Same as neutralPushText in packages/doener_models.
const neutral = {
  friend_check_in: 'Ein Freund ist gerade beim Döner. Öffne die App für Details.',
  new_place: 'Ein neuer Döner hat aufgemacht. Öffne die App für Details.',
};

// A push is only a signal (event type and ID). The text comes from the API
// with the device's fetch key, which the app leaves in the cache
// (push_worker_web.dart); without it the notification only names the type.
firebase.messaging().onBackgroundMessage(async (payload) => {
  const { type, id } = payload.data || {};
  if (!type || !id) return;
  let title = 'Döner App';
  let body = neutral[type] || 'Es gibt Neues in der Döner App.';
  let placeId;
  try {
    const stored = await (await caches.open('doener-push')).match('/push-key');
    const { key, api } = await stored.json();
    const response = await fetch(`${api}/push-events/${encodeURIComponent(id)}`, { headers: { authorization: `Push ${key}` } });
    if (response.ok) ({ title, body, placeId } = await response.json());
  } catch (_) {
    // Offline or no key yet: the neutral text stays.
  }
  await self.registration.showNotification(title, { body, icon: '/icons/Icon-192.png', tag: id, data: { placeId } });
});

self.addEventListener('notificationclick', (event) => {
  const placeId = event.notification.data && event.notification.data.placeId;
  event.notification.close();
  event.waitUntil(clients.openWindow(placeId ? `/app?place=${encodeURIComponent(placeId)}` : '/app'));
});
