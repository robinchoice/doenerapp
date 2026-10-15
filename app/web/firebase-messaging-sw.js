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
firebase.messaging();
