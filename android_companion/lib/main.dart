import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'companion_runner.dart';
import 'native.dart';
import 'plugin_install.dart';

void main() {
  final runner = CompanionRunner();
  // כמו במתאם של המחשב: חריגה אסינכרונית שתחמוק מהתפיסות בפנים הייתה
  // מפילה את המתאם בשקט. כאן היא נרשמת ביומן והמתאם ממשיך.
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    runApp(CompanionApp(runner: runner));
    // ה-main רץ פעם אחת לכל תהליך — כשפותחים את המסך, או כשהשירות הקים
    // את המנוע בעצמו (עלייה עם הטלפון, הקמה מחדש אחרי שהמערכת הרגה אותו).
    unawaited(runner.boot());
  }, (error, stack) => runner.log('שגיאה לא מטופלת: $error\n$stack'));
}

class CompanionApp extends StatelessWidget {
  const CompanionApp({super.key, required this.runner});

  final CompanionRunner runner;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF5B4B8A));
    return MaterialApp(
      title: 'מתאם חברותא',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: scheme, useMaterial3: true),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5B4B8A),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: StatusPage(runner: runner),
    );
  }
}

class StatusPage extends StatefulWidget {
  const StatusPage({super.key, required this.runner});

  final CompanionRunner runner;

  @override
  State<StatusPage> createState() => _StatusPageState();
}

class _StatusPageState extends State<StatusPage> {
  Timer? _tick;
  AppLifecycleListener? _lifecycle;
  bool? _startOnBoot;
  bool? _batteryExempt;

  @override
  void initState() {
    super.initState();
    // המצב (מחוברים, מונים) משתנה בלי אירוע, ולכן רענון קבוע.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    // הפטור מחיסכון בסוללה ניתן בחלון של המערכת; חוזרים ממנו כשהמסך
    // חוזר לחזית, ואז קוראים את המצב מחדש.
    _lifecycle = AppLifecycleListener(onResume: _loadSettings);
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final boot = await Native.getStartOnBoot();
      final exempt = await Native.isBatteryExempt();
      if (!mounted) return;
      setState(() {
        _startOnBoot = boot;
        _batteryExempt = exempt;
      });
    } catch (_) {
      // בלי ההגדרות הכרטיס פשוט אינו מוצג.
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final runner = widget.runner;
    return Scaffold(
      appBar: AppBar(title: const Text('מתאם חברותא')),
      body: ListenableBuilder(
        listenable: runner,
        builder: (context, _) {
          final snap = runner.snapshot();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _statusCard(context, runner),
              if (snap != null) _linkCard(context, snap),
              _pluginCard(context, snap),
              _backgroundCard(context),
              _howToCard(context),
              _logCard(context, runner),
            ],
          );
        },
      ),
    );
  }

  Widget _statusCard(BuildContext context, CompanionRunner runner) {
    final String title;
    if (runner.busy) {
      title = 'רגע…';
    } else {
      title = switch (runner.state) {
        CompanionState.active => 'המתאם ער ומסנכרן (127.0.0.1:${runner.port})',
        CompanionState.dormant => 'המתאם במצב שינה',
        CompanionState.stopped => 'המתאם כבוי',
      };
    }
    final snap = runner.snapshot();
    final engine = snap?['engine'];
    final pluginConnected = engine is Map && engine['owner'] != null;
    return _Section(
      title: title,
      children: [
        if (runner.startError != null)
          Text(
            'ההפעלה נכשלה: ${runner.startError}',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (runner.state == CompanionState.dormant && !runner.busy)
          Text(
            'אוצריא לא סנכרנה דרכו ${dormantAfter.inMinutes} דקות, ולכן '
            'הוא אינו משדר ואינו קולט. כשאוצריא תחפש אותו הוא יתעורר לבד '
            'תוך שניות.',
          ),
        if (snap != null) ...[
          _row('שם המכשיר', '${snap['deviceName']}'),
          _row(
            'קוד חברותא',
            snap['paired'] == true
                ? 'מוגדר'
                : 'לא מוגדר — מזינים אותו בלשונית חברותא באוצריא',
          ),
          _row(
            'התוסף באוצריא',
            pluginConnected ? 'מחובר ומסנכרן' : 'לא מחובר כרגע',
          ),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: runner.running
              ? OutlinedButton(
                  onPressed: runner.busy ? null : runner.stop,
                  child: const Text('עצירת המתאם'),
                )
              : FilledButton(
                  onPressed: runner.busy ? null : runner.start,
                  child: const Text('הפעלת המתאם'),
                ),
        ),
      ],
    );
  }

  Widget _linkCard(BuildContext context, Map<String, Object?> snap) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final peers = (snap['peers'] as List?) ?? const [];
    final links = (snap['links'] as List?) ?? const [];
    final lanError = snap['lanError'];
    return _Section(
      title: 'החברותא והרשת',
      children: [
        if (peers.isEmpty)
          const Text('אף אחד עדיין לא נשמע.')
        else
          for (final peer in peers)
            if (peer is Map)
              Text(
                '${peer['name']} — נשמע לפני '
                '${((now - ((peer['lastSeenMs'] as num?) ?? now)) / 1000).round()} שניות',
              ),
        const SizedBox(height: 8),
        Text(
          'דרך מה הטלפון משדר:',
          style: Theme.of(context).textTheme.labelLarge,
        ),
        if (links.isEmpty)
          const Text(
            'אין אף כרטיס רשת פעיל. הדליקו שיתוף אינטרנט בבלוטות\' '
            '(או נקודה חמה) וחברו אליו את המחשב.',
          )
        else
          for (final link in links)
            if (link is Map)
              Text(
                '${link['local']} → ${link['broadcast']}'
                '${link['sending'] == false ? ' (אינו משדר)' : ''}',
                textDirection: TextDirection.ltr,
              ),
        if (lanError != null)
          Text(
            'שגיאת רשת: $lanError',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const SizedBox(height: 8),
        Text(
          'התקבלו ${snap['datagramsReceived']} הודעות, '
          '${snap['datagramsFromOthers']} ממכשיר אחר, '
          '${snap['datagramsRejected']} נדחו '
          '(${snap['datagramsClockRejected']} בגלל פער שעונים).',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  /// המקבילה של "התקנת תוסף החברותא באוצריא" במתקין של המחשב: קישור
  /// `otzaria://plugin/install` שמבקש מאוצריא להוריד את התוסף מהחנות.
  Widget _pluginCard(BuildContext context, Map<String, Object?>? snap) {
    final engine = snap?['engine'];
    final connected = engine is Map && engine['owner'] != null;
    Future<void> install() async {
      final opened = await Native.openUri(pluginInstallUri());
      if (opened || !context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('אוצריא אינה מותקנת בטלפון הזה')),
      );
    }

    return _Section(
      title: 'תוסף החברותא באוצריא',
      children: [
        Text(
          connected
              ? 'התוסף מחובר. הכפתור מוריד מחנות התוספים של אוצריא את הגרסה '
                    'העדכנית שמתאימה לאוצריא שלכם.'
              : 'המתאם עובד עם תוסף החברותא שבתוך אוצריא. הכפתור פותח את '
                    'אוצריא, והיא מורידה את התוסף מחנות התוספים הרשמית שלה '
                    'ומבקשת לאשר את ההרשאות שלו.',
        ),
        Text(
          'ההורדה דורשת חיבור לאינטרנט. הסנכרון עצמו — לא.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: connected
              ? OutlinedButton(
                  onPressed: install,
                  child: const Text('הורדת עדכון לתוסף מהחנות'),
                )
              : FilledButton(
                  onPressed: install,
                  child: const Text('הורדה והתקנה של התוסף מהחנות'),
                ),
        ),
      ],
    );
  }

  Widget _backgroundCard(BuildContext context) {
    final boot = _startOnBoot;
    final exempt = _batteryExempt;
    if (boot == null && exempt == null) return const SizedBox.shrink();
    return _Section(
      title: 'ריצה ברקע',
      children: [
        if (boot != null)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('עולה עם הטלפון'),
            subtitle: const Text(
              'אחרי הפעלה מחדש המתאם עולה ישר למצב שינה, ומתעורר כשאוצריא '
              'מחפשת אותו. אין צורך לפתוח את המסך הזה.',
            ),
            value: boot,
            onChanged: (value) async {
              final actual = await Native.setStartOnBoot(value);
              if (mounted) setState(() => _startOnBoot = actual);
            },
          ),
        if (exempt == false) ...[
          const SizedBox(height: 8),
          const Text(
            'חיסכון הסוללה של הטלפון עלול לעצור את המתאם ברקע, או כשסוגרים '
            'את האפליקציה. במצב שינה המתאם כמעט אינו צורך סוללה.',
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.tonal(
              onPressed: Native.requestBatteryExempt,
              child: const Text('פטור מחיסכון בסוללה'),
            ),
          ),
        ] else if (exempt == true)
          const Text('פטור מחיסכון בסוללה: מאושר.'),
      ],
    );
  }

  Widget _howToCard(BuildContext context) => const _Section(
    title: 'חיבור בבלוטות\', בלי אינטרנט',
    children: [
      Text(
        '1. בטלפון: הגדרות ← נקודה חמה ושיתוף אינטרנט ← שיתוף אינטרנט '
        'בבלוטות\' — להדליק. אין צורך בחבילת גלישה.',
      ),
      Text(
        '2. במחשב: קליק ימני על סמל הבלוטות\' ← הצטרפות לרשת אישית ← '
        'בחירת הטלפון ← התחבר באמצעות ← נקודת גישה.',
      ),
      Text(
        '3. באוצריא, בטלפון ובמחשב: לשונית חברותא ← חיבור ישיר ← '
        'אותו קוד חברותא.',
      ),
    ],
  );

  Widget _logCard(BuildContext context, CompanionRunner runner) {
    final recent = runner.lines.reversed.take(200).toList();
    return _Section(
      title: 'יומן',
      trailing: IconButton(
        tooltip: 'העתקת היומן',
        icon: const Icon(Icons.copy),
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: runner.lines.join('\n')));
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('היומן הועתק')),
          );
        },
      ),
      children: [
        SelectableText(
          recent.isEmpty ? 'ריק' : recent.join('\n'),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ],
    );
  }

  static Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          TextSpan(text: value),
        ],
      ),
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.trailing});

  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    ),
  );
}
