import 'package:firebase_core/firebase_core.dart';

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    return const FirebaseOptions(
      apiKey: 'AIzaSyBBcZ8wq0m_oHXca6WbONsWac8S73AF4iM',
      appId: '1:991297629028:android:2e038e124e49852f97e871',
      messagingSenderId: '991297629028',
      projectId: 'attend-ad5e7',
      authDomain: 'attend-ad5e7.firebaseapp.com', // Optional
      storageBucket: 'attend-ad5e7.appspot.com',  // Optional
    );
  }
}
