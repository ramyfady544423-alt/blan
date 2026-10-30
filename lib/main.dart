import 'dart:async';
import 'dart:convert';
import 'dart:ui' show FontFeature;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

final notifications = FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.init();
  runApp(const StudyFlowApp());
}

// ============================================================
// NOTIFICATION SERVICE
// ============================================================

class NotificationService {
  static final Map<int, Timer> _linuxTimers = {};

  static Future<void> init() async {
    tzdata.initializeTimeZones();

    try {
      // flutter_timezone 4.1.0 returns a String.
      final String zone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(zone));
    } catch (e) {
      debugPrint('Could not detect timezone: $e');
      tz.setLocalLocation(tz.getLocation('Africa/Cairo'));
    }

    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      linux: LinuxInitializationSettings(
        defaultActionName: 'Open StudyFlow',
      ),
      windows: WindowsInitializationSettings(
        appName: 'StudyFlow',
        appUserModelId: 'com.studyflow.app',
        guid: 'cfef6e50-03ab-4273-ae7e-2528d1166fd3',
      ),
    );

    await notifications.initialize(settings);

    if (defaultTargetPlatform == TargetPlatform.android) {
      final androidPlugin = notifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      await androidPlugin?.requestNotificationsPermission();
      await androidPlugin?.requestExactAlarmsPermission();
    }
  }

  static Future<void> scheduleAlarm(
    int id,
    String title,
    DateTime when,
  ) async {
    if (when.isBefore(DateTime.now())) return;

    final scheduledDate = tz.TZDateTime.from(when, tz.local);

    try {
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          await notifications.zonedSchedule(
            id,
            'StudyFlow alarm',
            title,
            scheduledDate,
            const NotificationDetails(
              android: AndroidNotificationDetails(
                'study_alarms',
                'Study alarms',
                channelDescription: 'Study reminders and timer alerts',
                importance: Importance.max,
                priority: Priority.high,
                playSound: true,
                enableVibration: true,
              ),
            ),
            androidScheduleMode:
                AndroidScheduleMode.exactAllowWhileIdle,
            
            matchDateTimeComponents: null,
          );
          break;

        case TargetPlatform.windows:
          await notifications.zonedSchedule(
            id,
            'StudyFlow alarm',
            title,
            scheduledDate,
            const NotificationDetails(
              windows: WindowsNotificationDetails(),
            ),
            androidScheduleMode:
                AndroidScheduleMode.exactAllowWhileIdle,
          );
          break;

        case TargetPlatform.linux:
          // Linux does not support persistent scheduled notifications
          // through this plugin. Use a timer while the app is running.
          _linuxTimers[id]?.cancel();

          final delay = when.difference(DateTime.now());

          _linuxTimers[id] = Timer(delay, () async {
            _linuxTimers.remove(id);

            try {
              await notifications.show(
                id,
                'StudyFlow alarm',
                title,
                const NotificationDetails(
                  linux: LinuxNotificationDetails(),
                ),
              );
            } catch (e) {
              debugPrint('Linux notification error: $e');
            }
          });
          break;

        default:
          debugPrint(
            'Scheduled notifications are not configured for '
            '$defaultTargetPlatform.',
          );
      }
    } catch (e) {
      debugPrint('Could not schedule alarm $id: $e');
    }
  }

  static Future<void> cancel(int id) async {
    _linuxTimers.remove(id)?.cancel();

    try {
      await notifications.cancel(id);
    } catch (e) {
      debugPrint('Could not cancel notification $id: $e');
    }
  }
}

// ============================================================
// DATA MODELS
// ============================================================

class StudyTask {
  StudyTask({
    required this.id,
    required this.title,
    this.subject = 'General',
    this.done = false,
    this.priority = 1,
    this.minutes = 25,
  });

  final String id;
  String title;
  String subject;
  bool done;
  int priority;
  int minutes;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'subject': subject,
        'done': done,
        'priority': priority,
        'minutes': minutes,
      };

  factory StudyTask.fromJson(Map<String, dynamic> j) => StudyTask(
        id: j['id'],
        title: j['title'],
        subject: j['subject'] ?? 'General',
        done: j['done'] ?? false,
        priority: j['priority'] ?? 1,
        minutes: j['minutes'] ?? 25,
      );
}

class StudySession {
  StudySession({
    required this.task,
    required this.subject,
    required this.seconds,
    required this.endedAt,
    required this.mode,
  });

  final String task;
  final String subject;
  final String mode;
  final int seconds;
  final DateTime endedAt;

  Map<String, dynamic> toJson() => {
        'task': task,
        'subject': subject,
        'seconds': seconds,
        'endedAt': endedAt.toIso8601String(),
        'mode': mode,
      };

  factory StudySession.fromJson(Map<String, dynamic> j) =>
      StudySession(
        task: j['task'],
        subject: j['subject'],
        seconds: j['seconds'],
        endedAt: DateTime.parse(j['endedAt']),
        mode: j['mode'],
      );
}

class StudyAlarm {
  StudyAlarm({
    required this.id,
    required this.title,
    required this.when,
    this.enabled = true,
  });

  final int id;
  String title;
  DateTime when;
  bool enabled;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'when': when.toIso8601String(),
        'enabled': enabled,
      };

  factory StudyAlarm.fromJson(Map<String, dynamic> j) =>
      StudyAlarm(
        id: j['id'],
        title: j['title'],
        when: DateTime.parse(j['when']),
        enabled: j['enabled'] ?? true,
      );
}

// ============================================================
// LOCAL STORAGE
// ============================================================

class StudyStore extends ChangeNotifier {
  List<StudyTask> tasks = [];
  List<StudySession> sessions = [];
  List<StudyAlarm> alarms = [];

  int totalSeconds = 0;
  int streak = 0;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();

    tasks = (p.getStringList('tasks') ?? [])
        .map((e) => StudyTask.fromJson(jsonDecode(e)))
        .toList();

    sessions = (p.getStringList('sessions') ?? [])
        .map((e) => StudySession.fromJson(jsonDecode(e)))
        .toList();

    alarms = (p.getStringList('alarms') ?? [])
        .map((e) => StudyAlarm.fromJson(jsonDecode(e)))
        .toList();

    totalSeconds = p.getInt('totalSeconds') ?? 0;
    streak = p.getInt('streak') ?? 0;

    // Restore future alarms when the application starts.
    for (final alarm in alarms) {
      if (alarm.enabled && alarm.when.isAfter(DateTime.now())) {
        await NotificationService.scheduleAlarm(
          alarm.id,
          alarm.title,
          alarm.when,
        );
      }
    }

    notifyListeners();
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();

    await p.setStringList(
      'tasks',
      tasks.map((e) => jsonEncode(e.toJson())).toList(),
    );

    await p.setStringList(
      'sessions',
      sessions.map((e) => jsonEncode(e.toJson())).toList(),
    );

    await p.setStringList(
      'alarms',
      alarms.map((e) => jsonEncode(e.toJson())).toList(),
    );

    await p.setInt('totalSeconds', totalSeconds);
    await p.setInt('streak', streak);

    notifyListeners();
  }

  void addTask(StudyTask t) {
    tasks.insert(0, t);
    save();
  }

  void toggleTask(StudyTask t) {
    t.done = !t.done;
    save();
  }

  void deleteTask(StudyTask t) {
    tasks.remove(t);
    save();
  }

  void addSession(StudySession s) {
    sessions.insert(0, s);
    totalSeconds += s.seconds;
    save();
  }

  void addAlarm(StudyAlarm a) {
    alarms.add(a);
    save();
  }

  void deleteAlarm(StudyAlarm a) {
    alarms.remove(a);
    NotificationService.cancel(a.id);
    save();
  }
}

final store = StudyStore();

// ============================================================
// MAIN APP
// ============================================================

class StudyFlowApp extends StatefulWidget {
  const StudyFlowApp({super.key});

  @override
  State<StudyFlowApp> createState() => _StudyFlowAppState();
}

class _StudyFlowAppState extends State<StudyFlowApp> {
  @override
  void initState() {
    super.initState();
    store.load();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'StudyFlow',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xff0b1020),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff8b7cff),
          brightness: Brightness.dark,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xff151d32),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xff1a2440),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      home: const HomePage(),
    );
  }
}

// ============================================================
// NAVIGATION
// ============================================================

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int tab = 0;

  final pages = const [
    DashboardPage(),
    FocusPage(),
    TasksPage(),
    HistoryPage(),
    AlarmsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(child: pages[tab]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (v) => setState(() => tab = v),
        backgroundColor: const Color(0xff111a2d),
        indicatorColor: const Color(0xff39346d),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.space_dashboard_outlined),
            selectedIcon: Icon(Icons.space_dashboard),
            label: 'Overview',
          ),
          NavigationDestination(
            icon: Icon(Icons.timer_outlined),
            selectedIcon: Icon(Icons.timer),
            label: 'Focus',
          ),
          NavigationDestination(
            icon: Icon(Icons.checklist),
            label: 'Tasks',
          ),
          NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            label: 'Progress',
          ),
          NavigationDestination(
            icon: Icon(Icons.alarm_outlined),
            label: 'Alarms',
          ),
        ],
      ),
    );
  }
}

// ============================================================
// SHARED WIDGETS
// ============================================================

String durationText(int s) {
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  return h > 0 ? '${h}h ${m}m' : '${m}m';
}

String clockText(int s) {
  final h = (s ~/ 3600).toString().padLeft(2, '0');
  final m = ((s % 3600) ~/ 60).toString().padLeft(2, '0');
  final sec = (s % 60).toString().padLeft(2, '0');
  return '$h:$m:$sec';
}

extension _Empty on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

class StatCard extends StatelessWidget {
  const StatCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 21),
            const SizedBox(height: 13),
            Text(
              value,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(
                fontSize: 10,
                letterSpacing: 1.1,
                color: Colors.white60,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        if (trailing != null)
          Text(
            trailing!,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 12,
            ),
          ),
      ],
    );
  }
}

class EmptyPanel extends StatelessWidget {
  const EmptyPanel({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(
              icon,
              size: 34,
              color: const Color(0xffa99cff),
            ),
            const SizedBox(height: 10),
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }
}

class QuickAction extends StatelessWidget {
  const QuickAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: 18,
            horizontal: 8,
          ),
          child: Column(
            children: [
              Icon(
                icon,
                color: const Color(0xffb7aaff),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// DASHBOARD
// ============================================================

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final today = store.sessions
            .where(
              (s) => DateUtils.isSameDay(
                s.endedAt,
                DateTime.now(),
              ),
            )
            .fold<int>(0, (a, b) => a + b.seconds);

        final done = store.tasks.where((t) => t.done).length;

        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const SizedBox(height: 8),
            Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'STUDYFLOW',
                        style: TextStyle(
                          color: Color(0xffa99cff),
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2,
                        ),
                      ),
                      SizedBox(height: 5),
                      Text(
                        'Your study command center',
                        style: TextStyle(
                          fontSize: 25,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
                const CircleAvatar(
                  radius: 25,
                  backgroundColor: Color(0xff302b60),
                  child: Icon(
                    Icons.school_rounded,
                    color: Color(0xffc7bfff),
                    size: 28,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: StatCard(
                    label: 'TODAY',
                    value: durationText(today),
                    icon: Icons.today,
                    color: const Color(0xff9d8cff),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: StatCard(
                    label: 'TOTAL FOCUS',
                    value: durationText(store.totalSeconds),
                    icon: Icons.bolt,
                    color: const Color(0xff5bd6b0),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: StatCard(
                    label: 'TASKS DONE',
                    value: '$done / ${store.tasks.length}',
                    icon: Icons.task_alt,
                    color: const Color(0xffffbd69),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: StatCard(
                    label: 'SESSIONS',
                    value: '${store.sessions.length}',
                    icon: Icons.auto_graph,
                    color: const Color(0xff65b8ff),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            SectionTitle(
              'Up next',
              trailing:
                  '${store.tasks.where((t) => !t.done).length} remaining',
            ),
            const SizedBox(height: 10),
            if (store.tasks.where((t) => !t.done).isEmpty)
              const EmptyPanel(
                icon: Icons.celebration,
                title: 'All clear!',
                subtitle:
                    'Add a task and make your next study session count.',
              ),
            ...store.tasks
                .where((t) => !t.done)
                .take(3)
                .map((t) => TaskTile(task: t)),
            const SizedBox(height: 20),
            const SectionTitle('Quick launch'),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: QuickAction(
                    icon: Icons.timer,
                    label: 'Focus timer',
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              const FocusPage(fullPage: true),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: QuickAction(
                    icon: Icons.add_task,
                    label: 'New task',
                    onTap: () => showTaskDialog(context),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: QuickAction(
                    icon: Icons.alarm_add,
                    label: 'Alarm',
                    onTap: () => showAlarmDialog(context),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

// ============================================================
// FOCUS TIMER
// ============================================================

class FocusPage extends StatefulWidget {
  const FocusPage({super.key, this.fullPage = false});

  final bool fullPage;

  @override
  State<FocusPage> createState() => _FocusPageState();
}

class _FocusPageState extends State<FocusPage>
    with WidgetsBindingObserver {
  Timer? ticker;

  int remaining = 25 * 60;
  int elapsed = 0;
  int initial = 25 * 60;

  bool running = false;
  bool paused = false;

  String mode = 'Pomodoro';
  String subject = 'General';

  StudyTask? selectedTask;

  final taskController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    ticker?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    taskController.dispose();
    super.dispose();
  }

  void configure(String m) {
    ticker?.cancel();

    setState(() {
      mode = m;
      running = false;
      paused = false;
      elapsed = 0;

      initial = m == 'Pomodoro'
          ? 25 * 60
          : m == 'Short break'
              ? 5 * 60
              : m == 'Long break'
                  ? 15 * 60
                  : 30 * 60;

      remaining = initial;
    });
  }

  void configureCustom(int seconds) {
    ticker?.cancel();

    setState(() {
      mode = 'Custom';
      initial = seconds;
      remaining = seconds;
      elapsed = 0;
      running = false;
      paused = false;
    });
  }

  void start() {
    if (running) return;

    setState(() {
      running = true;
      paused = false;
    });

    ticker = Timer.periodic(
      const Duration(seconds: 1),
      (t) {
        if (!mounted) return;

        setState(() {
          elapsed++;

          if (mode != 'Stopwatch') {
            remaining--;

            if (remaining <= 0) {
              remaining = 0;
              t.cancel();
              running = false;
              _finish();
            }
          }
        });
      },
    );
  }

  void pause() {
    ticker?.cancel();

    setState(() {
      running = false;
      paused = true;
    });
  }

  void reset() {
    ticker?.cancel();

    setState(() {
      running = false;
      paused = false;
      elapsed = 0;
      remaining = initial;
    });
  }

  void _finish() {
    NotificationService.scheduleAlarm(
      9801,
      'Your $mode session is complete.',
      DateTime.now().add(const Duration(seconds: 1)),
    );

    _saveSession();
  }

  void _saveSession() {
    if (elapsed < 30) return;

    store.addSession(
      StudySession(
        task: selectedTask?.title ??
            taskController.text.trim().ifEmpty('Unassigned focus'),
        subject: subject,
        seconds: elapsed,
        endedAt: DateTime.now(),
        mode: mode,
      ),
    );
  }

  String _display() {
    return mode == 'Stopwatch' ? clockText(elapsed) : clockText(remaining);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final content = ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Focus studio',
                    style: TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (widget.fullPage)
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
            const Text(
              'A timer that turns effort into progress.',
              style: TextStyle(color: Colors.white54),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                'Pomodoro',
                'Short break',
                'Long break',
                'Custom',
                'Stopwatch',
              ].map((m) {
                return ChoiceChip(
                  label: Text(m),
                  selected: mode == m,
                  onSelected: (_) => configure(m),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 30,
                  horizontal: 20,
                ),
                child: Column(
                  children: [
                    Text(
                      mode.toUpperCase(),
                      style: const TextStyle(
                        letterSpacing: 2,
                        color: Colors.white54,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: 230,
                      height: 230,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          CircularProgressIndicator(
                            value: mode == 'Stopwatch'
                                ? null
                                : (initial == 0
                                    ? 0
                                    : remaining / initial),
                            strokeWidth: 10,
                            backgroundColor: Colors.white10,
                            color: const Color(0xffa99aff),
                            strokeCap: StrokeCap.round,
                          ),
                          Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _display(),
                                  style: const TextStyle(
                                    fontSize: 43,
                                    fontWeight: FontWeight.w800,
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                                Text(
                                  running
                                      ? 'IN SESSION'
                                      : paused
                                          ? 'PAUSED'
                                          : 'READY',
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    letterSpacing: 2,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 22),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton.filledTonal(
                          onPressed: reset,
                          icon: const Icon(Icons.restart_alt),
                          iconSize: 24,
                        ),
                        const SizedBox(width: 16),
                        SizedBox(
                          width: 140,
                          height: 52,
                          child: FilledButton.icon(
                            onPressed: running ? pause : start,
                            icon: Icon(
                              running ? Icons.pause : Icons.play_arrow,
                            ),
                            label: Text(running ? 'Pause' : 'Start'),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xff7668dc),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        IconButton.filledTonal(
                          onPressed: _saveSession,
                          icon: const Icon(Icons.save_alt),
                          iconSize: 22,
                        ),
                      ],
                    ),
                    if (mode == 'Custom')
                      Padding(
                        padding: const EdgeInsets.only(top: 18),
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final d = await showDurationPicker(
                              context,
                              initial,
                            );

                            if (d != null) configureCustom(d);
                          },
                          icon: const Icon(Icons.tune),
                          label: const Text('Set duration'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            const SectionTitle('Session details'),
            const SizedBox(height: 10),
            DropdownButtonFormField<StudyTask?>(
              value: selectedTask,
              decoration: const InputDecoration(
                labelText: 'Link to a task',
                prefixIcon: Icon(Icons.link),
              ),
              items: [
                const DropdownMenuItem<StudyTask?>(
                  value: null,
                  child: Text('No task selected'),
                ),
                ...store.tasks.map(
                  (t) => DropdownMenuItem<StudyTask?>(
                    value: t,
                    child: Text(
                      t.title,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
              onChanged: (v) => setState(() => selectedTask = v),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: taskController,
              decoration: const InputDecoration(
                labelText: 'Session label (optional)',
                prefixIcon: Icon(Icons.edit_note),
              ),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: subject,
              decoration: const InputDecoration(
                labelText: 'Subject',
              ),
              items: [
                'General',
                'Mathematics',
                'Science',
                'Physics',
                'Chemistry',
                'Biology',
                'English',
                'History',
                'Computer science',
                'Other',
              ].map((s) {
                return DropdownMenuItem(
                  value: s,
                  child: Text(s),
                );
              }).toList(),
              onChanged: (v) => setState(() => subject = v ?? 'General'),
            ),
            const SizedBox(height: 16),
            const Text(
              'Tip: use the save button to log a completed focus block early. '
              'Sessions are stored on this device.',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 12,
              ),
            ),
          ],
        );

        return widget.fullPage
            ? Scaffold(body: SafeArea(child: content))
            : content;
      },
    );
  }
}

// ============================================================
// CUSTOM TIMER DIALOG
// ============================================================

Future<int?> showDurationPicker(
  BuildContext context,
  int current,
) async {
  int hours = current ~/ 3600;
  int minutes = (current % 3600) ~/ 60;

  return showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Custom timer'),
      content: Row(
        children: [
          Expanded(
            child: TextFormField(
              initialValue: '$hours',
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Hours'),
              onChanged: (v) => hours = int.tryParse(v) ?? 0,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextFormField(
              initialValue: '$minutes',
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Minutes'),
              onChanged: (v) => minutes = int.tryParse(v) ?? 0,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(
              ctx,
              (hours * 3600 + minutes * 60).clamp(60, 86400),
            );
          },
          child: const Text('Set'),
        ),
      ],
    ),
  );
}

// ============================================================
// TASKS
// ============================================================

class TasksPage extends StatelessWidget {
  const TasksPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final pending = store.tasks.where((t) => !t.done).toList();
        final done = store.tasks.where((t) => t.done).toList();

        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Your tasks',
                    style: TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed: () => showTaskDialog(context),
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${pending.length} to do • ${done.length} completed',
              style: const TextStyle(color: Colors.white54),
            ),
            const SizedBox(height: 22),
            const SectionTitle('To do'),
            if (pending.isEmpty)
              const EmptyPanel(
                icon: Icons.check_circle_outline,
                title: 'Nothing pending',
                subtitle: 'Add your next assignment or study goal.',
              ),
            ...pending.map((t) => TaskTile(task: t)),
            if (done.isNotEmpty) ...[
              const SizedBox(height: 22),
              const SectionTitle('Completed'),
              ...done.map((t) => TaskTile(task: t)),
            ],
          ],
        );
      },
    );
  }
}

class TaskTile extends StatelessWidget {
  const TaskTile({super.key, required this.task});

  final StudyTask task;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 8,
        ),
        child: Row(
          children: [
            Checkbox(
              value: task.done,
              onChanged: (_) => store.toggleTask(task),
              activeColor: const Color(0xff8e80f3),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      decoration: task.done
                          ? TextDecoration.lineThrough
                          : null,
                      color: task.done ? Colors.white54 : null,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${task.subject} • ${task.minutes} min • '
                    '${['Low', 'Normal', 'High'][task.priority.clamp(0, 2)]} priority',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.white54,
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'delete') store.deleteTask(task);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'delete',
                  child: Text('Delete'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// ADD TASK DIALOG
// ============================================================

Future<void> showTaskDialog(BuildContext context) async {
  final title = TextEditingController();
  final subject = TextEditingController(text: 'General');

  int minutes = 25;
  int priority = 1;

  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: const Text('Create a task'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Task or assignment',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: subject,
                decoration: const InputDecoration(
                  labelText: 'Subject',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Expanded(child: Text('Estimated focus')),
                  DropdownButton<int>(
                    value: minutes,
                    items: [15, 25, 30, 45, 60, 90, 120]
                        .map(
                          (v) => DropdownMenuItem(
                            value: v,
                            child: Text('$v min'),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => set(() => minutes = v ?? 25),
                  ),
                ],
              ),
              Row(
                children: [
                  const Expanded(child: Text('Priority')),
                  DropdownButton<int>(
                    value: priority,
                    items: const [
                      DropdownMenuItem(
                        value: 0,
                        child: Text('Low'),
                      ),
                      DropdownMenuItem(
                        value: 1,
                        child: Text('Normal'),
                      ),
                      DropdownMenuItem(
                        value: 2,
                        child: Text('High'),
                      ),
                    ],
                    onChanged: (v) => set(() => priority = v ?? 1),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (title.text.trim().isNotEmpty) {
                store.addTask(
                  StudyTask(
                    id: DateTime.now()
                        .microsecondsSinceEpoch
                        .toString(),
                    title: title.text.trim(),
                    subject: subject.text.trim().ifEmpty('General'),
                    minutes: minutes,
                    priority: priority,
                  ),
                );
              }

              Navigator.pop(ctx);
            },
            child: const Text('Add task'),
          ),
        ],
      ),
    ),
  );

  title.dispose();
  subject.dispose();
}

// ============================================================
// HISTORY AND PROGRESS
// ============================================================

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final today = store.sessions
            .where(
              (s) => DateUtils.isSameDay(
                s.endedAt,
                DateTime.now(),
              ),
            )
            .toList();

        final week = store.sessions
            .where(
              (s) => DateTime.now().difference(s.endedAt).inDays < 7,
            )
            .fold<int>(0, (a, b) => a + b.seconds);

        final subjectTotals = <String, int>{};

        for (final s in store.sessions) {
          subjectTotals[s.subject] =
              (subjectTotals[s.subject] ?? 0) + s.seconds;
        }

        final sortedSubjects = subjectTotals.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));

        final maxSubjectSeconds = subjectTotals.values.fold<int>(
          1,
          (a, b) => a > b ? a : b,
        );

        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Your progress',
              style: TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.w800,
              ),
            ),
            const Text(
              'Every focused minute adds up.',
              style: TextStyle(color: Colors.white54),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: StatCard(
                    label: 'TODAY',
                    value: durationText(
                      today.fold<int>(0, (a, b) => a + b.seconds),
                    ),
                    icon: Icons.today,
                    color: const Color(0xffa99aff),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: StatCard(
                    label: 'THIS WEEK',
                    value: durationText(week),
                    icon: Icons.date_range,
                    color: const Color(0xff5bd6b0),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            const SectionTitle('Time by subject'),
            const SizedBox(height: 10),
            if (subjectTotals.isEmpty)
              const EmptyPanel(
                icon: Icons.insights,
                title: 'Your chart starts here',
                subtitle:
                    'Complete a timer session to see your study breakdown.',
              ),
            ...sortedSubjects.map((e) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text(e.key)),
                        Text(
                          durationText(e.value),
                          style: const TextStyle(
                            color: Colors.white60,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: e.value / maxSubjectSeconds,
                        minHeight: 9,
                        backgroundColor: Colors.white10,
                        color: const Color(0xff9385ff),
                      ),
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 18),
            const SectionTitle('Recent sessions'),
            if (store.sessions.isEmpty)
              const EmptyPanel(
                icon: Icons.history,
                title: 'No sessions yet',
                subtitle:
                    'Your saved study sessions will appear here.',
              ),
            ...store.sessions.take(30).map(
              (s) => Card(
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xff302b60),
                    child: Icon(
                      Icons.timer,
                      color: Color(0xffc6bcff),
                    ),
                  ),
                  title: Text(
                    s.task,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    '${s.subject} • '
                    '${DateFormat('MMM d, h:mm a').format(s.endedAt)}',
                  ),
                  trailing: Text(
                    durationText(s.seconds),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ============================================================
// ALARMS PAGE
// ============================================================

class AlarmsPage extends StatelessWidget {
  const AlarmsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final sorted = [...store.alarms]
          ..sort((a, b) => a.when.compareTo(b.when));

        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Alarms & reminders',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed: () => showAlarmDialog(context),
                  icon: const Icon(Icons.add_alarm),
                  label: const Text('New'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Schedule a reminder for a class, revision block, or break.',
              style: TextStyle(color: Colors.white54),
            ),
            const SizedBox(height: 20),
            if (sorted.isEmpty)
              const EmptyPanel(
                icon: Icons.alarm_add,
                title: 'No alarms scheduled',
                subtitle:
                    'Create a reminder and StudyFlow will notify you.',
              ),
            ...sorted.map(
              (a) => Card(
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xff302b60),
                    child: Icon(
                      Icons.alarm,
                      color: Color(0xffc6bcff),
                    ),
                  ),
                  title: Text(
                    a.title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  subtitle: Text(
                    DateFormat('EEE, MMM d • h:mm a').format(a.when),
                  ),
                  trailing: IconButton(
                    onPressed: () => store.deleteAlarm(a),
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Colors.white54,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ============================================================
// CREATE ALARM DIALOG
// ============================================================

Future<void> showAlarmDialog(BuildContext context) async {
  final title = TextEditingController(text: 'Study reminder');

  DateTime when = DateTime.now().add(
    const Duration(minutes: 30),
  );

  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: const Text('New reminder'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: title,
              decoration: const InputDecoration(
                labelText: 'Reminder name',
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                final now = DateTime.now();

                final d = await showDatePicker(
                  context: ctx,
                  initialDate: when.isBefore(now) ? now : when,
                  firstDate: DateTime(now.year, now.month, now.day),
                  lastDate: now.add(const Duration(days: 365)),
                );

                if (d != null && ctx.mounted) {
                  final t = await showTimePicker(
                    context: ctx,
                    initialTime: TimeOfDay.fromDateTime(when),
                  );

                  if (t != null) {
                    set(() {
                      when = DateTime(
                        d.year,
                        d.month,
                        d.day,
                        t.hour,
                        t.minute,
                      );
                    });
                  }
                }
              },
              icon: const Icon(Icons.calendar_month),
              label: Text(
                DateFormat('EEE, MMM d • h:mm a').format(when),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (title.text.trim().isNotEmpty &&
                  when.isAfter(DateTime.now())) {
                final a = StudyAlarm(
                  id: DateTime.now()
                      .millisecondsSinceEpoch
                      .remainder(2147483647),
                  title: title.text.trim(),
                  when: when,
                );

                store.addAlarm(a);

                await NotificationService.scheduleAlarm(
                  a.id,
                  a.title,
                  a.when,
                );
              }

              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save alarm'),
          ),
        ],
      ),
    ),
  );

  title.dispose();
}