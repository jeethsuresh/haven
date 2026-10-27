import 'package:flutter/material.dart';
import 'api.dart';
import 'controller.dart';
import 'model.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HavenApp());
}

const ink = Color(0xFF193D34),
    canvas = Color(0xFFF5F6F2),
    muted = Color(0xFF6D7D76);

class HavenApp extends StatelessWidget {
  const HavenApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Haven',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: canvas,
      colorScheme: ColorScheme.fromSeed(
        seedColor: ink,
        primary: ink,
        surface: Colors.white,
      ),
      fontFamily: 'sans-serif',
      cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFDFE5DF)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    ),
    home: const HavenHome(),
  );
}

class HavenHome extends StatefulWidget {
  const HavenHome({super.key});
  @override
  State<HavenHome> createState() => _HavenHomeState();
}

class _HavenHomeState extends State<HavenHome> {
  late final HavenController c;
  String section = 'All media', query = '';
  final search = TextEditingController();
  @override
  void initState() {
    super.initState();
    c = HavenController()..addListener(_update);
    c.initialize();
  }

  void _update() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    c.removeListener(_update);
    c.dispose();
    search.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() task) async {
    try {
      await task();
    } catch (e) {
      c.report('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (c.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!c.ready) return _login();
    final wide = MediaQuery.sizeOf(context).width > 900;
    return Scaffold(
      appBar: wide ? null : AppBar(title: const Text('Haven')),
      drawer: wide ? null : Drawer(child: _sidebar()),
      body: Row(
        children: [
          if (wide) SizedBox(width: 238, child: _sidebar()),
          Expanded(
            child: Column(
              children: [
                Expanded(child: _body(wide)),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 12,
                  ),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    border: Border(top: BorderSide(color: Color(0xFFE4E9E3))),
                  ),
                  child: Text(
                    c.message,
                    style: const TextStyle(fontSize: 12, color: muted),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _brand({bool light = false}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: light ? Colors.white.withValues(alpha: .12) : ink,
          borderRadius: BorderRadius.circular(13),
        ),
        child: const Icon(Icons.hub_outlined, color: Colors.white, size: 26),
      ),
      const SizedBox(width: 12),
      Text(
        'haven',
        style: TextStyle(
          fontSize: 29,
          fontWeight: FontWeight.w700,
          letterSpacing: -1,
          color: light ? Colors.white : ink,
        ),
      ),
    ],
  );
  Widget _login() => Scaffold(
    body: Center(
      child: SingleChildScrollView(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 620),
          padding: const EdgeInsets.all(40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _brand(),
              const SizedBox(height: 64),
              const Text(
                'A home for\nevery memory.',
                style: TextStyle(
                  fontSize: 48,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                  letterSpacing: -2,
                  color: ink,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Back up your phone to the devices you own. Browse your library from anywhere.',
                style: TextStyle(fontSize: 19, height: 1.6, color: muted),
              ),
              const SizedBox(height: 36),
              const Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  Chip(
                    avatar: Icon(Icons.phone_android, size: 18),
                    label: Text('Phone · source'),
                  ),
                  Chip(
                    avatar: Icon(Icons.computer, size: 18),
                    label: Text('Desktop · sink'),
                  ),
                  Chip(
                    avatar: Icon(Icons.grid_view, size: 18),
                    label: Text('Web · viewer'),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: c.busy || c.config['dev'] == true
                    ? null
                    : () => c.signIn(),
                icon: const Icon(Icons.login),
                label: const Text('Continue with Gravitas'),
              ),
              if (c.config['dev'] == true) ...[
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: c.busy ? null : () => c.signIn(development: true),
                  child: const Text('Enter local development workspace'),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Development mode · loopback backend · no real account',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ],
              if (c.busy) ...[
                const SizedBox(height: 20),
                const LinearProgressIndicator(),
              ],
              const SizedBox(height: 24),
              Text(c.message, style: const TextStyle(color: muted)),
              const SizedBox(height: 24),
              Text(
                'Backend: ${c.api.base}',
                style: const TextStyle(fontSize: 12, color: muted),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  Widget _sidebar() => Container(
    color: ink,
    child: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 30, 18, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 10, bottom: 40),
                      child: _brand(light: true),
                    ),
                    _label('YOUR LIBRARY'),
                    _nav('All media', Icons.photo_library_outlined),
                    _nav('Photos', Icons.image_outlined),
                    _nav('Videos', Icons.videocam_outlined),
                    _nav('Audio', Icons.music_note_outlined),
                    const SizedBox(height: 24),
                    _label('EVERYTHING ELSE'),
                    _nav('Files', Icons.folder_outlined),
                    _nav('Contacts', Icons.contacts_outlined),
                    _nav('Notes', Icons.description_outlined),
                    const SizedBox(height: 24),
                    _label('YOUR NETWORK'),
                    _nav('Devices', Icons.devices_outlined),
                    _nav('Transfers', Icons.sync_alt),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                children: [
                  Icon(
                    Icons.route_outlined,
                    size: 18,
                    color: Color(0xFFB5D4BF),
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Direct connections\nOriginals stay on your devices',
                      style: TextStyle(
                        color: Color(0xFFD1E1D6),
                        fontSize: 11,
                        height: 1.7,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                const CircleAvatar(
                  radius: 16,
                  backgroundColor: Color(0xFF527064),
                  child: Icon(
                    Icons.person_outline,
                    size: 19,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    c.name,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Sign out',
                  onPressed: () => run(c.logout),
                  icon: const Icon(
                    Icons.logout,
                    color: Colors.white70,
                    size: 18,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  Widget _label(String value) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 0, 10),
    child: Text(
      value,
      style: const TextStyle(
        color: Color(0xFF92B1A1),
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.7,
      ),
    ),
  );
  Widget _nav(String label, IconData icon) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Material(
      color: section == label
          ? Colors.white.withValues(alpha: .13)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(9),
      child: ListTile(
        dense: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        leading: Icon(icon, size: 19, color: Colors.white70),
        title: Text(
          label,
          style: TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: section == label ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        onTap: () {
          setState(() {
            section = label;
            query = '';
            search.clear();
          });
          if (MediaQuery.sizeOf(context).width <= 900) Navigator.pop(context);
        },
      ),
    ),
  );
  List<MediaAsset> get filtered => c.assets.where((a) {
    final match = switch (section) {
      'Photos' => a.kind == 'media' && a.mime.startsWith('image/'),
      'Videos' => a.kind == 'media' && a.mime.startsWith('video/'),
      'Audio' => a.kind == 'media' && a.mime.startsWith('audio/'),
      'Files' => a.kind == 'file',
      'Contacts' => a.kind == 'contact',
      'Notes' => a.kind == 'note',
      _ => a.kind == 'media',
    };
    return match && a.path.toLowerCase().contains(query.toLowerCase());
  }).toList();
  Widget _body(bool wide) {
    final media = ['All media', 'Photos', 'Videos', 'Audio'].contains(section);
    return SingleChildScrollView(
      padding: EdgeInsets.all(wide ? 36 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'YOUR PERSONAL CLOUD',
                      style: TextStyle(
                        color: muted,
                        fontSize: 10,
                        letterSpacing: 2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      section == 'All media' ? 'Media library' : section,
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w600,
                        color: ink,
                        letterSpacing: -1,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      media
                          ? 'Every moment, connected across your devices.'
                          : section == 'Devices'
                          ? 'Choose where your library lives.'
                          : section == 'Transfers'
                          ? 'Direct device-to-device transfers. No TURN relay.'
                          : 'One shared library, across all your sinks.',
                      style: const TextStyle(color: muted, fontSize: 13),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Refresh library',
                onPressed: () => run(c.refresh),
                icon: const Icon(Icons.refresh, color: ink),
              ),
              if (!c.isDesktop && !c.isAndroid)
                const SizedBox(width: 4)
              else
                IconButton(
                  tooltip: 'Configure this device',
                  onPressed: _settings,
                  icon: const Icon(Icons.tune, color: ink),
                ),
            ],
          ),
          const SizedBox(height: 30),
          if (media) _stats(wide),
          if (media) const SizedBox(height: 30),
          if (section == 'Devices')
            _devices()
          else if (section == 'Transfers')
            _transfers()
          else ...[
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: search,
                    onChanged: (v) => setState(() => query = v),
                    decoration: const InputDecoration(
                      hintText: 'Search your library',
                      prefixIcon: Icon(Icons.search, size: 20),
                      contentPadding: EdgeInsets.all(14),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                if (!c.busy &&
                    (c.roles.contains('source') || c.roles.contains('sink')))
                  OutlinedButton.icon(
                    onPressed: () => c.scan(),
                    icon: const Icon(Icons.sync, size: 18),
                    label: const Text('Scan now'),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            if (c.busy) const LinearProgressIndicator(),
            if (filtered.isEmpty)
              _empty(media)
            else if (media)
              LayoutBuilder(
                builder: (context, box) {
                  final count = (box.maxWidth / 220).floor().clamp(1, 6);
                  return GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: filtered.length,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: count,
                      crossAxisSpacing: 16,
                      mainAxisSpacing: 16,
                      childAspectRatio: .93,
                    ),
                    itemBuilder: (context, i) => _tile(filtered[i]),
                  );
                },
              )
            else
              _folder('', filtered),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _stats(bool wide) {
    final media = c.assets.where((a) => a.kind == 'media').toList();
    final safe = media.where((a) => a.copies > 0).length;
    final sinks = c.devices
        .where(
          (d) => (d['roles'] as List).contains('sink') && d['revoked'] != true,
        )
        .length;
    final values = [
      ('Media items', '${media.length}', Icons.photo_library_outlined),
      ('Stored on a sink', '$safe', Icons.verified_outlined),
      ('Storage devices', '$sinks', Icons.dns_outlined),
    ];
    return LayoutBuilder(
      builder: (context, box) => Wrap(
        spacing: 14,
        runSpacing: 14,
        children: [
          for (final v in values)
            Container(
              width: wide ? (box.maxWidth - 28) / 3 : box.maxWidth,
              padding: const EdgeInsets.all(21),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: const Color(0xFFE1E7DF)),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Icon(v.$3, color: muted, size: 23),
                  const SizedBox(width: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        v.$1,
                        style: const TextStyle(fontSize: 12, color: muted),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        v.$2,
                        style: const TextStyle(
                          fontSize: 25,
                          fontWeight: FontWeight.w600,
                          color: ink,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _empty(bool media) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 64),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xFFE1E7DF)),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: const BoxDecoration(
            color: canvas,
            shape: BoxShape.circle,
          ),
          child: Icon(
            media ? Icons.add_photo_alternate_outlined : Icons.folder_open,
            color: ink,
            size: 40,
          ),
        ),
        const SizedBox(height: 22),
        Text(
          query.isNotEmpty
              ? 'No matching files'
              : media
              ? 'Your library starts here'
              : 'Nothing here yet',
          style: const TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w600,
            color: ink,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          query.isNotEmpty
              ? 'Try a different filename.'
              : media
              ? 'Enable your phone as a source and a desktop as a sink.\nThumbnails will appear here after a scan.'
              : section == 'Contacts' || section == 'Notes'
              ? 'The structured namespace is ready. Native contacts and notes\nadapters are scaffolded for a later release.'
              : 'Add files to the Files folder on a desktop sink.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: muted, height: 1.7),
        ),
        const SizedBox(height: 24),
        if (!c.isDesktop && !c.isAndroid)
          const Chip(
            label: Text('Install the native apps to connect your devices'),
          )
        else
          FilledButton.icon(
            onPressed: _settings,
            icon: const Icon(Icons.devices, size: 18),
            label: const Text('Set up this device'),
          ),
      ],
    ),
  );
  Widget _tile(MediaAsset asset) => Card(
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: const BorderSide(color: Color(0xFFE1E7DF)),
    ),
    child: InkWell(
      onTap: () => _details(asset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Thumbnail(api: c.api, asset: asset),
                if (asset.mime.startsWith('video/'))
                  const Center(
                    child: Icon(
                      Icons.play_circle_outline,
                      size: 44,
                      color: Colors.white,
                    ),
                  ),
                Positioned(
                  right: 10,
                  top: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .94),
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          asset.copies > 0
                              ? Icons.check_circle
                              : Icons.schedule,
                          size: 12,
                          color: asset.copies > 0 ? ink : muted,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          asset.copies > 0 ? 'Stored' : 'Pending',
                          style: const TextStyle(fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  asset.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: ink,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${readableBytes(asset.size)} · ${asset.copies} sink ${asset.copies == 1 ? 'copy' : 'copies'}',
                  style: const TextStyle(fontSize: 10, color: muted),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  Widget _folder(String prefix, List<MediaAsset> items) {
    final folders = <String, List<MediaAsset>>{};
    final files = <MediaAsset>[];
    for (final a in items) {
      final relative = a.path.substring(prefix.length);
      if (relative.contains('/')) {
        final part = relative.split('/').first;
        folders.putIfAbsent(part, () => []).add(a);
      } else {
        files.add(a);
      }
    }
    return Card(
      child: Column(
        children: [
          for (final group in folders.entries)
            ExpansionTile(
              initiallyExpanded: true,
              leading: const Icon(Icons.folder_outlined, color: ink),
              title: Text(group.key, style: const TextStyle(fontSize: 14)),
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 20),
                  child: _folder('$prefix${group.key}/', group.value),
                ),
              ],
            ),
          for (final a in files)
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: Text(a.name),
              subtitle: Text(
                '${readableBytes(a.size)} · ${a.copies} sink copies',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _details(a),
            ),
        ],
      ),
    );
  }

  Widget _devices() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (!c.isAndroid && !c.isDesktop)
        const Padding(
          padding: EdgeInsets.only(bottom: 20),
          child: Text(
            'Web viewers cache thumbnails. Configure storage and gallery access in the native apps.',
            style: TextStyle(color: muted),
          ),
        ),
      if (c.isAndroid || c.isDesktop)
        Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: FilledButton.icon(
            onPressed: _settings,
            icon: const Icon(Icons.tune),
            label: const Text('Configure this device'),
          ),
        ),
      for (final d in c.devices)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Card(
            child: ListTile(
              contentPadding: const EdgeInsets.all(18),
              leading: Icon(
                d['platform'] == 'android'
                    ? Icons.phone_android
                    : d['platform'] == 'web'
                    ? Icons.language
                    : Icons.computer,
                size: 28,
                color: ink,
              ),
              title: Text(
                '${d['name']}${d['id'] == c.deviceID ? ' · this device' : ''}',
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 9),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final role in d['roles'])
                      Chip(
                        label: Text(role, style: const TextStyle(fontSize: 11)),
                        visualDensity: VisualDensity.compact,
                      ),
                    Chip(
                      label: Text(
                        d['revoked'] == true
                            ? 'Revoked'
                            : DateTime.now().millisecondsSinceEpoch ~/ 1000 -
                                      (d['seen'] as int) <
                                  45
                            ? 'Online'
                            : 'Offline',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
              trailing: d['revoked'] == true
                  ? null
                  : IconButton(
                      tooltip: 'Revoke device access',
                      onPressed: () => run(() async {
                        await c.api.request(
                          'DELETE',
                          '/api/devices/${d['id']}',
                        );
                        await c.refresh();
                      }),
                      icon: const Icon(Icons.link_off, color: muted),
                    ),
            ),
          ),
        ),
    ],
  );
  Widget _transfers() {
    final jobs = c.transfers.where((t) => t['status'] != 'superseded').toList();
    return jobs.isEmpty
        ? const Padding(
            padding: EdgeInsets.symmetric(vertical: 70),
            child: Center(
              child: Text(
                'No transfers yet. Connect a source and a sink.',
                style: TextStyle(color: muted),
              ),
            ),
          )
        : Column(
            children: [
              for (final job in jobs)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Card(
                    child: ListTile(
                      leading: Icon(
                        job['status'] == 'complete'
                            ? Icons.verified_outlined
                            : Icons.sync,
                        color: ink,
                      ),
                      title: Text(
                        c.assets
                                .where((a) => a.id == job['asset_id'])
                                .firstOrNull
                                ?.name ??
                            'Media file',
                      ),
                      subtitle: Text(
                        '${_deviceName(job['from'])} → ${_deviceName(job['to'])}',
                      ),
                      trailing: Text(
                        (job['status'] as String).replaceAll('_', ' '),
                        style: const TextStyle(color: muted, fontSize: 12),
                      ),
                    ),
                  ),
                ),
            ],
          );
  }

  String _deviceName(String id) =>
      c.devices.where((d) => d['id'] == id).firstOrNull?['name'] ?? 'Device';
  void _details(MediaAsset a) => showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 10, 28, 38),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            a.name,
            style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 20),
          Text('${a.copies} verified sink copies · ${readableBytes(a.size)}'),
          const SizedBox(height: 12),
          SelectableText(a.path),
          const SizedBox(height: 18),
          const Text('SHA-256', style: TextStyle(fontSize: 11, color: muted)),
          SelectableText(a.hash, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 18),
          Text(
            '${(a.data['revisions'] as List).length} revisions retained in the catalog',
          ),
          if (a.data['conflict_of'] != null)
            const Padding(
              padding: EdgeInsets.only(top: 15),
              child: Text(
                'Conflict copy preserved from a concurrent edit.',
                style: TextStyle(color: Colors.orange),
              ),
            ),
        ],
      ),
    ),
  );
  Future<void> _settings() async {
    var source = c.roles.contains('source'), sink = c.roles.contains('sink');
    final name = TextEditingController(text: c.name);
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('This device'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: 'Device name'),
                  ),
                  const SizedBox(height: 20),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Source'),
                    subtitle: Text(
                      c.isAndroid
                          ? 'Discover photos, videos, and audio in your gallery.'
                          : 'Publish media and other files from this device.',
                    ),
                    value: source,
                    onChanged: (v) => set(() => source = v),
                  ),
                  if (c.isDesktop) ...[
                    const Divider(),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Repository folder'),
                      subtitle: Text(
                        c.local.root.isEmpty
                            ? 'Choose a folder before enabling sink mode'
                            : c.local.root,
                      ),
                      trailing: IconButton(
                        onPressed: c.roles.contains('sink')
                            ? null
                            : () => run(() async {
                                await c.chooseRoot();
                                set(() {});
                              }),
                        icon: const Icon(Icons.folder_open),
                      ),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Media folder (optional)'),
                      subtitle: Text(
                        c.local.mediaRoot.isEmpty
                            ? 'Defaults to Media/ inside the repository'
                            : c.local.mediaRoot,
                      ),
                      trailing: IconButton(
                        onPressed: c.roles.contains('sink')
                            ? null
                            : () => run(() async {
                                await c.chooseRoot(media: true);
                                set(() {});
                              }),
                        icon: const Icon(Icons.folder_open),
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Sink'),
                      subtitle: const Text(
                        'Store originals and replicate local file edits.',
                      ),
                      value: sink,
                      onChanged: (v) => set(() => sink = v),
                    ),
                  ],
                  const SizedBox(height: 14),
                  const Text(
                    'Every device is also a viewer. This scaffold scans and transfers while the app is open.',
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                c.name = name.text;
                try {
                  await c.configure([
                    'viewer',
                    if (source) 'source',
                    if (sink) 'sink',
                  ]);
                  if (context.mounted) Navigator.pop(context);
                  await c.refresh();
                } catch (e) {
                  c.report('$e');
                }
              },
              child: const Text('Save device'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
  }
}

class Thumbnail extends StatefulWidget {
  final HavenApi api;
  final MediaAsset asset;
  const Thumbnail({super.key, required this.api, required this.asset});
  @override
  State<Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<Thumbnail> {
  late Future<dynamic> future;
  @override
  void initState() {
    super.initState();
    future = widget.api.thumbnail(widget.asset);
  }

  @override
  void didUpdateWidget(covariant Thumbnail old) {
    super.didUpdateWidget(old);
    if (old.asset.revision != widget.asset.revision ||
        old.asset.id != widget.asset.id) {
      future = widget.api.thumbnail(widget.asset);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: future,
    builder: (context, snapshot) => snapshot.hasData
        ? Image.memory(snapshot.data, fit: BoxFit.cover)
        : Container(
            color: const Color(0xFFE4EBE2),
            child: Icon(
              widget.asset.mime.startsWith('video/')
                  ? Icons.videocam_outlined
                  : widget.asset.mime.startsWith('audio/')
                  ? Icons.music_note
                  : Icons.image_outlined,
              size: 46,
              color: const Color(0xFF8CA293),
            ),
          ),
  );
}
