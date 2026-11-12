import 'package:flutter/material.dart';

import '../../session.dart';
import '../../widgets/discard_guard.dart';
import '../backup_alert.dart';
import '../shell.dart' show NavItem, navItems, tabGroupOf;
import 'settings_activity.dart';
import 'settings_admin.dart';
import 'settings_notifications.dart';
import 'settings_sections.dart';
import 'settings_widgets.dart';

/// Personal preferences of the signed-in user on this device, plus the two administrator tools (Backup, Manutenção de dados). The system parameters are the screens of the avatar menu (Parâmetros dos módulos) and the Fiscal module.
/// [section] opens a specific section, for example `'account'`.
Future<void> showUserSettings(BuildContext context, Session session, {String? section}) => showDialog<void>(
  context: context,
  builder: (_) => SettingsDialog(session: session, section: section),
);

class _Section {
  const _Section(this.id, this.icon, this.label, this.build);

  final String id;
  final IconData icon;
  final String label;
  final Widget Function(BuildContext context, Session session, OpenSubView open, VoidCallback signOut) build;
}

/// Sections only administrators see.
const _adminOnly = {'backup', 'admin'};

/// Reachable by link (section: 'activity') but not listed in the menu: it is already under Conta e acesso.
const _hiddenFromMenu = {'activity'};

/// Old names of sections that were merged (links and saved places may still say 'print' or 'about').
const _sectionAlias = {'print': 'appearance', 'about': 'data'};

/// System screens that are reached from where they matter (the duplicates strip on the customer, product and supplier lists), not from here.
const _notListedHere = {'duplicates'};

final _sections = <_Section>[
  // Related sections share one entry: fewer items to scan, and what belongs together is read together.
  _Section(
    'appearance',
    Icons.palette_outlined,
    'Aparência e impressão',
    (c, s, open, out) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppearanceSection(session: s),
        PrintSection(session: s),
      ],
    ),
  ),
  _Section('general', Icons.tune, 'Geral', (c, s, open, out) => GeneralSection(session: s, open: open)),
  _Section('notifications', Icons.notifications_outlined, 'Notificações', (c, s, open, out) => NotificationsSection(session: s)),
  _Section('account', Icons.person_outline, 'Conta e acesso', (c, s, open, out) => AccountSection(session: s, open: open, onSignOut: out)),
  _Section('activity', Icons.history, 'Minha atividade', (c, s, open, out) => ActivityView(session: s)),
  _Section(
    'data',
    Icons.devices_other_outlined,
    'Dispositivo e sobre',
    (c, s, open, out) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DataSection(session: s),
        AboutSection(session: s),
      ],
    ),
  ),
  _Section('backup', Icons.backup_outlined, 'Backup', (c, s, open, out) => BackupSection(session: s)),
  _Section('admin', Icons.storage_outlined, 'Manutenção de dados', (c, s, open, out) => AdminSection(session: s, open: open)),
];

class _SubView {
  const _SubView(this.title, this.builder);

  final String title;
  final WidgetBuilder builder;
}

/// Large two-pane settings window: sections on the left, the chosen section on the right. A button inside a section can open a
/// sub-view in the right pane (with a back arrow) so long tools do not pile up in one scroll.
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.session, this.section});

  final Session session;
  final String? section;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  static const _wideFrom = 640.0;

  String? _selected;
  final _subs = <_SubView>[];

  /// Backup problem found when the window opened; marks the Backup item in the menu.
  BackupAlert? _backupAlert;

  /// Views inside the window (the backup form) register their unsaved-edit check here; every way out goes through [_guard].
  final _dirty = DirtyRegistry();

  List<_Section> get _visible => [
    for (final s in _sections)
      if (!_adminOnly.contains(s.id) || widget.session.isAdmin) s,
  ];

  @override
  void initState() {
    super.initState();
    final want = _sectionAlias[widget.section] ?? widget.section;
    _selected = _visible.any((s) => s.id == want) ? want : null;
    if (widget.session.isAdmin) {
      fetchBackupAlert(widget.session).then((a) {
        if (mounted && a != null) setState(() => _backupAlert = a);
      });
    }
  }

  Future<void> _guard(VoidCallback action) => _dirty.guard(context, () {
    if (mounted) action();
  });

  void _select(String id) => _guard(() {
    setState(() {
      _selected = id;
      _subs.clear();
    });
  });

  void _subBack() => _guard(() => setState(_subs.removeLast));

  void _close() => _guard(() => Navigator.pop(context));

  void _open(String title, WidgetBuilder builder) => setState(() => _subs.add(_SubView(title, builder)));

  void _signOut() {
    Navigator.pop(context);
    widget.session.logout();
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final width = (screen.width - 48).clamp(280.0, 1040.0);
    final height = (screen.height - 48).clamp(320.0, 760.0);
    final wide = width >= _wideFrom;
    final selected = wide ? (_selected ?? 'appearance') : _selected;
    return DirtyScope(
      registry: _dirty,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          _guard(() {
            if (_subs.isNotEmpty) {
              setState(_subs.removeLast);
            } else if (!wide && _selected != null) {
              setState(() => _selected = null);
            } else {
              Navigator.pop(context);
            }
          });
        },
        child: Dialog(
          insetPadding: const EdgeInsets.all(24),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: width,
            height: height,
            child: ListenableBuilder(
              listenable: widget.session,
              builder: (context, _) => Column(
                children: [
                  _header(context, wide, selected),
                  const Divider(height: 1),
                  Expanded(
                    child: wide
                        ? Row(
                            children: [
                              SizedBox(width: 220, child: _nav(selected)),
                              const VerticalDivider(width: 1),
                              Expanded(child: _content(context, selected)),
                            ],
                          )
                        : (selected == null ? _nav(null) : _content(context, selected)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, bool wide, String? selected) {
    final theme = Theme.of(context);
    final canGoBack = !wide && selected != null && _subs.isEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          if (canGoBack)
            IconButton(
              key: const ValueKey('settings-back-to-menu'),
              tooltip: 'Voltar às preferências',
              onPressed: () => _guard(() => setState(() => _selected = null)),
              icon: const Icon(Icons.arrow_back),
            ),
          Expanded(child: Text('Preferências', style: theme.textTheme.titleLarge)),
          IconButton(key: const ValueKey('settings-close'), tooltip: 'Fechar', onPressed: _close, icon: const Icon(Icons.close)),
        ],
      ),
    );
  }

  /// System screens (not modules) the user may open: Parâmetros dos módulos and, for admins, Usuários e acesso (Usuários, Permissões and Auditoria are its tabs).
  List<({NavItem item, String title, IconData icon})> get _screenLinks => [
    for (final i in navItems())
      if (i.section == 'Sistema' &&
          i.shownTo(widget.session) &&
          !_notListedHere.contains(i.id) &&
          (tabGroupOf(i.id) == null || tabGroupOf(i.id)!.tabs.first.id == i.id))
        (item: i, title: tabGroupOf(i.id)?.title ?? i.title, icon: tabGroupOf(i.id)?.icon ?? i.icon),
  ];

  Widget _sectionTile(_Section s, String? selected) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: ListTile(
        key: ValueKey('settings-nav-${s.id}'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        selected: s.id == selected,
        selectedTileColor: cs.secondaryContainer,
        selectedColor: cs.onSecondaryContainer,
        leading: Icon(s.icon),
        title: Text(s.label),
        trailing: s.id == 'backup' && _backupAlert != null
            ? Tooltip(
                message: _backupAlert!.title,
                child: Icon(Icons.error, key: const ValueKey('settings-backup-badge'), size: 18, color: cs.error),
              )
            : null,
        onTap: () => _select(s.id),
      ),
    );
  }

  /// A system screen listed here opens on the main window: the settings window closes first (after the unsaved-edit check).
  Widget _screenTile(({NavItem item, String title, IconData icon}) l) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: ListTile(
      key: ValueKey('settings-screen-${l.item.id}'),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      leading: Icon(l.icon),
      title: Text(l.title),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: () => _guard(() {
        Navigator.pop(context);
        SettingsLinks.open?.call(l.item.id);
      }),
    ),
  );

  Widget _nav(String? selected) {
    final menu = _visible.where((s) => !_hiddenFromMenu.contains(s.id));
    final screens = SettingsLinks.open == null ? const <({NavItem item, String title, IconData icon})>[] : _screenLinks;
    final adminSections = [
      for (final s in menu)
        if (_adminOnly.contains(s.id)) s,
    ];
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      children: [
        for (final s in menu)
          if (!_adminOnly.contains(s.id)) _sectionTile(s, selected),
        // Everything that is not personal sits under one heading: system screens first, then the administrator tools.
        if (screens.isNotEmpty || adminSections.isNotEmpty)
          Padding(
            key: const ValueKey('settings-admin-heading'),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              widget.session.isAdmin ? 'Administração' : 'Sistema',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600),
            ),
          ),
        for (final l in screens) _screenTile(l),
        for (final s in adminSections) _sectionTile(s, selected),
      ],
    );
  }

  Widget _content(BuildContext context, String? selected) {
    final theme = Theme.of(context);
    final section = _visible.firstWhere((s) => s.id == selected, orElse: () => _visible.first);
    final sub = _subs.isEmpty ? null : _subs.last;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 24, 0),
          child: Row(
            children: [
              if (sub != null)
                IconButton(key: const ValueKey('settings-sub-back'), tooltip: 'Voltar', onPressed: _subBack, icon: const Icon(Icons.arrow_back))
              else
                const SizedBox(width: 8),
              Expanded(
                child: Text(
                  sub == null ? section.label : sub.title,
                  key: const ValueKey('settings-title'),
                  style: theme.textTheme.headlineSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: KeyedSubtree(
                  key: ValueKey('${section.id}/${_subs.length}'),
                  child: sub == null ? section.build(context, widget.session, _open, _signOut) : sub.builder(context),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// How the settings window opens a system screen on the main window. The Shell sets [open] while it is on screen; without it the window lists no screens.
class SettingsLinks {
  static void Function(String id)? open;
}
