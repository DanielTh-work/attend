import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert'; // For JSON encode/decode
import 'firebase_options.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:math';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart'; // Add this at the top
import 'dart:async';


void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Prevent duplicate initialization
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } on FirebaseException catch (e) {
    if (e.code == 'duplicate-app') {
      // Ignore duplicate app error
      debugPrint('Firebase already initialized.');
    } else {
      rethrow; // Let other errors bubble up
    }
  }


  final authProvider = AuthProvider();
  await authProvider.loadSavedCredentials();

  runApp(
    ChangeNotifierProvider.value(
      value: authProvider,
      child: const MyApp(),
    ),
  );
}

class AttendanceRecord {
  final String courseId;
  final String courseName;
  final DateTime timestamp;
  final String status; // 'attended' or 'absent'

  AttendanceRecord({
    required this.courseId,
    required this.courseName,
    required this.timestamp,
    required this.status,
  });
}


class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Attendance ',
      debugShowCheckedModeBanner: false,
      initialRoute: context.watch<AuthProvider>().email != null ? '/dashboard' : '/login',
      routes: {
        '/login': (_) => const LoginScreen(),
        '/dashboard': (_) => const DashboardScreen(),
        '/signup': (_) => const SignUpScreen(),
      },
      theme: ThemeData(
        primarySwatch: Colors.blue,
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8.0),
          ),
        ),
      ),
    );
  }
}

class AuthProvider with ChangeNotifier {
  String? _email;
  String? get email => _email;

  List<AttendanceRecord> _attendanceRecords = [];
  List<AttendanceRecord> get attendanceRecords => _attendanceRecords;
  Future<void> loadCombinedAttendance() async {
    if (_email == null) return;

    try {
      // 1. Load historical attendance
      final historySnapshot = await FirebaseFirestore.instance
          .collection('attendance_records')
          .where('email', isEqualTo: _email)
          .get();

      final history = historySnapshot.docs.map((doc) {
        final data = doc.data();
        return AttendanceRecord(
          courseId: data['courseId'],
          courseName: data['courseName'],
          timestamp: DateTime.parse(data['timestamp']),
          status: data['status'] ?? 'attended',
        );
      }).toList();

      // 2. Load today's schedule and mark 'absent' by default
      final today = _dayFromInt(DateTime.now().weekday);
      final scheduleSnapshot = await FirebaseFirestore.instance
          .collection('courses')
          .where('days', arrayContains: today)
          .get();

      final nowDate = DateTime.now().toIso8601String().substring(0, 10);
      final todaySchedule = scheduleSnapshot.docs.map((doc) {
        final courseId = doc.id;
        final courseName = doc['name'] ?? 'Unnamed';
        return AttendanceRecord(
          courseId: courseId,
          courseName: courseName,
          timestamp: DateTime.now(),
          status: 'absent',
        );
      }).toList();

      // 3. Overwrite 'absent' with 'attended' if attended today
      final todayKeys = todaySchedule.map((r) => r.courseId + nowDate).toSet();
      for (var record in history) {
        final dateKey = record.courseId + record.timestamp.toIso8601String().substring(0, 10);
        if (todayKeys.contains(dateKey)) {
          todaySchedule.removeWhere((r) =>
          r.courseId == record.courseId &&
              r.timestamp.toIso8601String().substring(0, 10) == nowDate);
          todaySchedule.add(record); // overwrite
        }
      }

      // 4. Merge all
      _attendanceRecords = [...history, ...todaySchedule];
      notifyListeners();
    } catch (e) {
      print("⚠️ Error loading combined attendance: $e");
    }
  }

  void addAttendanceRecord(String courseId, String courseName) async {
    if (_email == null) return;

    final newRecord = AttendanceRecord(
      courseId: courseId,
      courseName: courseName,
      timestamp: DateTime.now(),
      status: 'attended',
    );


    _attendanceRecords.add(newRecord);
    await _saveAttendanceRecordsToStorage();
    notifyListeners();

    // 🔥 Save to Firestore
    try {
      await FirebaseFirestore.instance.collection('attendance_records').add({
        'email': _email,
        'courseId': courseId,
        'courseName': courseName,
        'timestamp': newRecord.timestamp.toIso8601String(),
        'status': 'attended'
      });
    } catch (e) {
      print("⚠️ Failed to write to Firestore: $e");
    }
  }

  Future<void> loadAttendanceRecordsManually() async {
    if (_email == null) return;

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('attendance_records')
          .where('email', isEqualTo: _email)
          .get();

      _attendanceRecords = snapshot.docs.map((doc) {
        final data = doc.data();
        return AttendanceRecord(
          courseId: data['courseId'] ?? '',
          courseName: data['courseName'] ?? '',
          timestamp: DateTime.parse(data['timestamp']),
          status: 'attended', // These records came from attendance log
        );

      }).toList();

      notifyListeners();
    } catch (e) {
      print("⚠️ Failed to load from Firestore: $e");
    }
  }

  Future<void> loadSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final savedEmail = prefs.getString('saved_email');
    final savedPassword = prefs.getString('saved_password');
    final remember = prefs.getBool('remember_me') ?? false;

    if (remember && savedEmail != null && savedPassword != null) {
      await login(savedEmail, savedPassword);
    }
  }

  Future<void> saveLoginPreferences(String email, String password, bool rememberMe) async {
    final prefs = await SharedPreferences.getInstance();
    if (rememberMe) {
      await prefs.setString('saved_email', email);
      await prefs.setString('saved_password', password);
      await prefs.setBool('remember_me', true);
    } else {
      await prefs.remove('saved_email');
      await prefs.remove('saved_password');
      await prefs.setBool('remember_me', false);
    }
  }

  Future<void> loadTodayScheduleWithAttendance() async {
    if (_email == null) return;

    try {
      final today = _dayFromInt(DateTime.now().weekday); // 'Monday', etc.
      final scheduleSnapshot = await FirebaseFirestore.instance
          .collection('courses')
          .where('days', arrayContains: today)
          .get();

      final attendanceSnapshot = await FirebaseFirestore.instance
          .collection('attendance_records')
          .where('email', isEqualTo: _email)
          .get();

      final attendedCourseIds = attendanceSnapshot.docs.map((doc) {
        final data = doc.data();
        final ts = DateTime.parse(data['timestamp']);
        return data['courseId'] + ts.toIso8601String().substring(0, 10); // Unique per day
      }).toSet();

      final nowDate = DateTime.now().toIso8601String().substring(0, 10);
      _attendanceRecords = scheduleSnapshot.docs.map((doc) {
        final courseId = doc.id;
        final courseName = doc['name'] ?? 'Unnamed';
        final timestamp = DateTime.now(); // We'll use today's date
        final key = courseId + nowDate;

        return AttendanceRecord(
          courseId: courseId,
          courseName: courseName,
          timestamp: timestamp,
          status: attendedCourseIds.contains(key) ? 'attended' : 'absent',
        );
      }).toList();

      notifyListeners();
    } catch (e) {
      print("⚠️ Failed to load schedule and attendance: $e");
    }
  }

  String _dayFromInt(int weekday) {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return days[weekday - 1];
  }

  Future<void> login(String email, String password, {bool rememberMe = false}) async {
    try {
      final userCredential = await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: email, password: password);
      _email = userCredential.user?.email;
      await _loadAttendanceRecordsFromStorage();
      await saveLoginPreferences(email, password, rememberMe);
      notifyListeners();
    } catch (e) {
      _email = null;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> resetPassword(String email) async {
    await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
  }

  Future<void> signup(String email, String password) async {
    try {
      final userCredential = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(email: email, password: password);
      _email = userCredential.user?.email;
      await _loadAttendanceRecordsFromStorage();
      notifyListeners();
    } catch (e) {
      _email = null;
      notifyListeners();
      rethrow;
    }
  }
  void deleteAttendanceRecord(AttendanceRecord targetRecord) async {
    // 1. Delete locally
    _attendanceRecords.removeWhere((record) =>
    record.courseId == targetRecord.courseId &&
        record.timestamp == targetRecord.timestamp);
    await _saveAttendanceRecordsToStorage();
    notifyListeners();

    // 2. Delete from Firestore
    if (_email != null) {
      try {
        final snapshot = await FirebaseFirestore.instance
            .collection('attendance_records')
            .where('email', isEqualTo: _email)
            .where('courseId', isEqualTo: targetRecord.courseId)
            .where('timestamp', isEqualTo: targetRecord.timestamp.toIso8601String())
            .get();

        for (final doc in snapshot.docs) {
          await doc.reference.delete();
        }
      } catch (e) {
        print("⚠️ Error deleting from Firestore: $e");
      }
    }
  }



  void logout() {
    _email = null;
    _attendanceRecords = [];
    notifyListeners();
  }

  Future<void> _saveAttendanceRecordsToStorage() async {
    if (_email == null) return;
    final prefs = await SharedPreferences.getInstance();
    final key = 'attendance_${_email!}';

    final recordsJson = _attendanceRecords.map((record) => json.encode({
      'courseId': record.courseId,
      'courseName': record.courseName,
      'timestamp': record.timestamp.toIso8601String(),
    })).toList();

    await prefs.setStringList(key, recordsJson);
  }

  Future<void> _loadAttendanceRecordsFromStorage() async {
    if (_email == null) return;
    final prefs = await SharedPreferences.getInstance();
    final key = 'attendance_${_email!}';
    final recordsJson = prefs.getStringList(key) ?? [];

    _attendanceRecords = recordsJson.map((recordStr) {
      final map = json.decode(recordStr);
      return AttendanceRecord(
        courseId: map['courseId'],
        courseName: map['courseName'],
        timestamp: DateTime.parse(map['timestamp']),
        status: 'attended',
      );

    }).toList();
  }
}


class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  bool rememberMe = false;
  void _showForgotPasswordDialog(BuildContext context) {
    final resetEmailController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset Password'),
        content: TextField(
          controller: resetEmailController,
          decoration: const InputDecoration(labelText: 'Enter your email'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final email = resetEmailController.text.trim();
              Navigator.pop(context); // Close dialog
              try {
                await Provider.of<AuthProvider>(context, listen: false)
                    .resetPassword(email);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Password reset email sent.')),
                );
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Error: ${e.toString()}')),
                );
              }
            },
            child: const Text('Send'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.fingerprint, size: 80, color: Colors.blueAccent),
              const SizedBox(height: 16),
              const Text(
                'Attendance',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text('Welcome back! Please log in to continue.'),
              const SizedBox(height: 30),
              Card(
                elevation: 6,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      TextFormField(
                        controller: emailController,
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          prefixIcon: Icon(Icons.email),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: passwordController,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Password',
                          prefixIcon: Icon(Icons.lock),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Checkbox(
                            value: rememberMe,
                            onChanged: (value) => setState(() => rememberMe = value ?? false),
                          ),
                          const Text('Remember Me'),
                          const Spacer(),
                          TextButton(
                            onPressed: () => _showForgotPasswordDialog(context),
                            child: const Text('Forgot Password?'),
                          ),

                        ],
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () async {
                            try {
                              await Provider.of<AuthProvider>(context, listen: false).login(
                                emailController.text.trim(),
                                passwordController.text,
                                rememberMe: rememberMe,
                              );


                              final userEmail = Provider.of<AuthProvider>(context, listen: false).email;
                              if (userEmail != null) {
                                Navigator.pushNamed(context, '/dashboard');
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Login failed. Please check your credentials.')),
                                );
                              }
                            } catch (e) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Login failed: ${e.toString()}')),
                              );
                            }
                          },

                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                          child: const Text('Login', style: TextStyle(fontSize: 16)),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextButton(
                        onPressed: () => Navigator.pushNamed(context, '/signup'),
                        child: const Text("Don't have an account? Sign Up"),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign Up')),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            TextFormField(
              controller: emailController,
              decoration: const InputDecoration(
                labelText: 'Email',
                prefixIcon: Icon(Icons.email),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password',
                prefixIcon: Icon(Icons.lock),
              ),
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () async {
                  try {
                    await Provider.of<AuthProvider>(context, listen: false)
                        .signup(emailController.text.trim(), passwordController.text);
                    Navigator.pushReplacementNamed(context, '/dashboard');
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Sign up failed: ${e.toString()}')),
                    );
                  }
                },
                child: const Text('Create Account'),
              ),
            )
          ],
        ),
      ),
    );
  }
}

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final userEmail = context.watch<AuthProvider>().email;
    final username = userEmail?.split('@').first ?? 'User';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Attendance Assistant'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () {
              context.read<AuthProvider>().logout();
              Navigator.pushNamed(context, '/login');
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Hi! $username',
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
            const SizedBox(height: 30),
            Expanded(
              child: ListView(
                children: [
                  const SizedBox(height: 20),
                  _buildOptionCard(
                    context,
                    title: 'Take Attendance',
                    icon: Icons.add_task,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => CourseSelectionScreen()),
                    ),
                  ),
                  const SizedBox(height: 20),
                  _buildOptionCard(
                    context,
                    title: 'View Attendance Records',
                    icon: Icons.history,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const AttendanceRecordScreen()),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOptionCard(BuildContext context,
      {required String title,
        required IconData icon,
        required VoidCallback onTap}) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding:
          const EdgeInsets.symmetric(vertical: 24.0, horizontal: 16.0),
          child: Row(
            children: [
              Icon(icon, size: 36, color: Colors.blueAccent),
              const SizedBox(width: 20),
              Text(title, style: const TextStyle(fontSize: 18)),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _buildOptionCard(BuildContext context,
    {required String title, required IconData icon, required VoidCallback onTap}) {
  return Card(
    elevation: 4,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24.0, horizontal: 16.0),
        child: Row(
          children: [
            Icon(icon, size: 36, color: Colors.blueAccent),
            const SizedBox(width: 20),
            Text(title, style: const TextStyle(fontSize: 18)),
          ],
        ),
      ),
    ),
  );
}



class CourseSelectionScreen extends StatelessWidget {
  CourseSelectionScreen({super.key});

  final List<Map<String, String>> courses = [
    {'id': '101', 'name': 'Networking Protocols', 'mac': 'fe:7d:f4:af:86:d7'},
    {'id': '102', 'name': 'Embedded Systems', 'mac': 'fa:79:f0:ab:82:d3'},
    {'id': '103', 'name': 'AI Fundamentals', 'mac': 'bc:57:29:02:99:87'},
  ];


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Select Course')),
      body: ListView.builder(
        itemCount: courses.length,
        itemBuilder: (context, index) {
          final course = courses[index];
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: ListTile(
              title: Text(course['name']!),
              subtitle: Text('Course ID: ${course['id']}'),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TakeAttendanceScreen(
                      courseId: course['id']!,
                      courseName: course['name']!,
                      courseMacAddress: course['mac']!,
                    ),
                  ),
                );
              }
              ,
            ),
          );
        },
      ),
    );
  }
}



class TakeAttendanceScreen extends StatefulWidget {
  final String courseId;
  final String courseName;
  final String courseMacAddress;

  const TakeAttendanceScreen({
    super.key,
    required this.courseId,
    required this.courseName,
    required this.courseMacAddress,
  });


  @override
  State<TakeAttendanceScreen> createState() => _TakeAttendanceScreenState();
}

class _TakeAttendanceScreenState extends State<TakeAttendanceScreen> {
  late String targetMacAddress; // MAC of the beacon
  int secondsRemaining = 10;
  Timer? countdownTimer;


  String detectedMac = "N/A";
  int beaconRSSI = 0;
  double estimatedDistance = -1;
  bool isScanning = true;
  bool beaconFound = false;
  DateTime? connectedAt;
  Timer? _connectionTimer;

  bool get canTakeAttendance {
    if (connectedAt == null) return false;
    return DateTime.now().difference(connectedAt!) >= const Duration(seconds: 20);
  }


  Future<void> requestPermissionsAndScan() async {
    final statuses = await [
      Permission.location,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();

    if (statuses[Permission.location]!.isGranted &&
        statuses[Permission.bluetoothScan]!.isGranted &&
        statuses[Permission.bluetoothConnect]!.isGranted) {
      startScan();
    } else {
      print('Permissions not granted');
    }
  }

  @override
  void initState() {
    super.initState();
    targetMacAddress = widget.courseMacAddress.toLowerCase();
    requestPermissionsAndScan();
  }

  void startScan() async {
    setState(() {
      isScanning = true;
      beaconFound = false;
      detectedMac = "N/A";
      beaconRSSI = 0;
      estimatedDistance = -1;
    });

    await FlutterBluePlus.stopScan();
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
    // ✅ Continuous RSSI update listener (only once)
    FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult result in results) {
        final mac = result.device.id.id.toLowerCase();
        if (mac == targetMacAddress && connectedAt != null) {
          setState(() {
            beaconRSSI = result.rssi;
            estimatedDistance = _estimateDistance(result.rssi);
          });
        }
      }
    });
    FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult result in results) {
        final mac = result.device.id.id;
        final name = result.device.name;
        final rssi = result.rssi;

        print("🔍 Found → Name: $name | MAC: $mac | RSSI: $rssi");

        if (mac.toLowerCase() == targetMacAddress) {
          // 🔌 Connect to the beacon
          result.device.connect(autoConnect: false).then((_) {
            print('✅ Connected to $mac');

            setState(() {
              detectedMac = mac;
              beaconRSSI = rssi;
              estimatedDistance = _estimateDistance(rssi);
              beaconFound = true;
              isScanning = false;
            });
            connectedAt = DateTime.now();

            connectedAt = DateTime.now();
            secondsRemaining = 20;

            countdownTimer?.cancel();
            countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
              final elapsed = DateTime.now().difference(connectedAt!).inSeconds;
              setState(() {
                secondsRemaining = max(0, 20 - elapsed);
              });

              // 🔁 Update RSSI and distance
              // 🆕 Live RSSI + distance updater during countdown
              FlutterBluePlus.scanResults.listen((results) {
                for (ScanResult result in results) {
                  final mac = result.device.id.id.toLowerCase();
                  if (mac == targetMacAddress && connectedAt != null) {
                    setState(() {
                      beaconRSSI = result.rssi;
                      estimatedDistance = _estimateDistance(result.rssi);
                    });
                  }
                }
              });


              // ❌ Out of range: cancel timer
              if (estimatedDistance > 5.0 || estimatedDistance == -1) {
                timer.cancel();
                _connectionTimer?.cancel();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("⚠️ Beacon is out of range. Stay within 5 meters.")),
                );
                setState(() {
                  connectedAt = null;
                  secondsRemaining = 20;
                });
                return;
              }

              // ✅ Timer finished
              if (secondsRemaining <= 0) {
                timer.cancel(); // attendance now allowed
              }
            });


            FlutterBluePlus.stopScan();
          }).catchError((e) {
            print('❌ Failed to connect: $e');
          });

          break;
        }
      }
    });


    Future.delayed(const Duration(seconds: 40), () {
      if (!beaconFound) {
        setState(() {
          isScanning = false;
        });
      }
    });
  }



  double _estimateDistance(int rssi) {
    const int txPower = -59; // Calibrated signal strength at 1 meter
    if (rssi == 0) return -1.0;
    return pow(10, (txPower - rssi) / (10 * 2)).toDouble();
  }
  Future<bool> isClassInSession(String courseId) async {
    try {
      final doc = await FirebaseFirestore.instance.collection('courses').doc(courseId).get();
      final data = doc.data();
      if (data == null) return false;

      List<dynamic> days = data['days'] ?? [];
      String startTimeStr = data['startTime'] ?? "00:00";
      String endTimeStr = data['endTime'] ?? "00:00";

      final now = DateTime.now();
      final currentDay = _dayFromInt(now.weekday); // "Monday", etc.
      final currentTime = TimeOfDay.fromDateTime(now);

      if (!days.contains(currentDay)) return false;

      TimeOfDay startTime = _parseTime(startTimeStr);
      TimeOfDay endTime = _parseTime(endTimeStr);

      return _isWithinTimeRange(currentTime, startTime, endTime);
    } catch (e) {
      print('⚠️ Error validating class session: $e');
      return false;
    }
  }

  String _dayFromInt(int weekday) {
    const dayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return dayNames[weekday - 1];
  }

  TimeOfDay _parseTime(String timeStr) {
    final parts = timeStr.split(':');
    return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
  }

  bool _isWithinTimeRange(TimeOfDay now, TimeOfDay start, TimeOfDay end) {
    int toMinutes(TimeOfDay t) => t.hour * 60 + t.minute;
    final nowMin = toMinutes(now);
    return nowMin >= toMinutes(start) && nowMin <= toMinutes(end);
  }


  @override
  Widget build(BuildContext context) {
    final username = context.watch<AuthProvider>().email?.split('@').first ?? 'User';

    return Scaffold(
      appBar: AppBar(title: const Text('Take Attendance')),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Hi! $username', style: const TextStyle(fontSize: 20)),
            const SizedBox(height: 40),

            _buildInfoRow('Course ID:', widget.courseId),
            _buildInfoRow('Course Name:', widget.courseName),
            _buildInfoRow('Timestamp:', DateTime.now().toString()),
            const SizedBox(height: 20),

            _buildInfoRow('Beacon MAC:', detectedMac),
            _buildInfoRow('RSSI:', beaconRSSI.toString()),
            _buildInfoRow('Distance:', estimatedDistance > 0 ? estimatedDistance.toStringAsFixed(2) + ' m' : 'N/A'),

            const SizedBox(height: 20),

// 🔄 Show scanning status
            if (isScanning)
              const Center(child: CircularProgressIndicator())
            else if (!beaconFound)
              const Center(child: Text("Beacon not found. Please move closer or try again.")),

            const Spacer(),
            if (connectedAt != null && !canTakeAttendance) ...[
              const SizedBox(height: 10),
              Text(
                "⏳ Please stay connected... $secondsRemaining seconds left",
                style: const TextStyle(color: Colors.orange),
              ),

            ],

// ✅ Show Take Attendance button (below scanning status)
            Center(
              child: ElevatedButton(
                onPressed: estimatedDistance > 0 && estimatedDistance <= 5.0 && canTakeAttendance

                    ? () async {
                  final allowed = await isClassInSession(widget.courseId);
                  if (allowed) {
                    _showConfirmationDialog(context);
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('⏰ Attendance not allowed — class is not in session.')),
                    );
                  }
                }
                    : null,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 40, vertical: 15),
                  child: Text('Take Attendance', style: TextStyle(fontSize: 18)),
                ),
              ),
            ),


            const Spacer(),

          ],

        ),
      ),
    );
  }

  void _showConfirmationDialog(BuildContext context) {
    context.read<AuthProvider>().addAttendanceRecord(widget.courseId, widget.courseName);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Attendance Recorded!'),
        content: const Text('Your attendance has been successfully recorded.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(width: 10),
          Flexible(child: Text(value)),
        ],
      ),
    );
  }


}


class AttendanceRecordScreen extends StatelessWidget {
  const AttendanceRecordScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();

    // ✅ Always load today's schedule regardless of existing records
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AuthProvider>().loadCombinedAttendance();
    });


    final records = authProvider.attendanceRecords;


    return Scaffold(
      appBar: AppBar(title: const Text('Your Attendance Records')),
      body: records.isEmpty
          ? const Center(child: Text('No attendance records yet.'))
          : ListView.builder(
        itemCount: records.length,
        itemBuilder: (context, index) {
          final record = records[index];
          return Dismissible(
            key: Key('${record.courseId}_${record.timestamp.toIso8601String()}'),
            // Make sure this key is unique
            direction: DismissDirection.endToStart,
            background: Container(
              color: Colors.red,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: const Icon(Icons.delete, color: Colors.white),
            ),
            onDismissed: (_) {
              context.read<AuthProvider>().deleteAttendanceRecord(record);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('${record.courseName} deleted')),
              );
            },

            child: ListTile(
              leading: Icon(
                record.status == 'attended' ? Icons.check_circle : Icons.cancel,
                color: record.status == 'attended' ? Colors.green : Colors.red,
              ),
              title: Text(record.courseName),
              subtitle: Text(
                'Course ID: ${record.courseId}\nStatus: ${record.status.toUpperCase()}\nDate: ${record.timestamp.toLocal()}',
              ),
            ),

          );
        },
      ),

    );
  }
}

