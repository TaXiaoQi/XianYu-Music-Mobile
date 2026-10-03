part of 'settings_category_page.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

extension _SettingsCategoryPageWatch on _SettingsCategoryPageState {
  List<Widget> _watch(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
    SettingsNotifier n,
  ) {
    return [
      _sectionHeader(context, tr('腕上联动')),
      _CardGroup(
        children: [
          _watchLinkageTile(context, ref, s, n),
          _watchCloudTile(context, s, n),
          _watchTransferTile(context, ref, s),
        ],
      ),
      _sectionHeader(context, tr('设备管理')),
      _CardGroup(
        children: [
          _watchLinkStatusTile(context, ref, s),
          _watchConnectTile(context, ref, s),
          _watchWakeTile(context, ref),
          _watchDisconnectTile(context, ref, s),
          _watchResetAuthTile(context, s, n),
        ],
      ),
    ];
  }

  Widget _watchLinkageTile(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
    SettingsNotifier n,
  ) {
    final enabled = s?.watchLinkageEnabled ?? true;
    final watchName = ref.watch(watchLinkConnectedNameProvider);
    final subtitle = !enabled
        ? tr('关闭后手表将无法遥控播放')
        : watchName.isNotEmpty
            ? tr('已连接：{name}', {'name': watchName})
            : tr('连接手机时可用手表遥控播放');
    return _switchTile(
      context,
      icon: Icons.watch_outlined,
      title: tr('腕上联动'),
      subtitle: subtitle,
      value: enabled,
      onChanged: (v) async {
        await n.setWatchLinkageEnabled(v);
        if (v) {
          final ctrl = ref.read(watchLinkControllerProvider);
          if (!await ctrl.hasLinkPermission()) {
            await ctrl.requestLinkPermission();
          }
        }
      },
    );
  }

  Widget _watchCloudTile(
    BuildContext context,
    AppSettings? s,
    SettingsNotifier n,
  ) {
    final enabled = s?.watchLinkCloudEnabled ?? true;
    final subtitle = !enabled
        ? tr('关闭后手表仅在蓝牙连接时可用')
        : tr('蓝牙不可用时经服务器中继保持连接');
    return _switchTile(
      context,
      icon: Icons.cloud_sync_outlined,
      title: tr('云端兜底通道'),
      subtitle: subtitle,
      value: enabled,
      onChanged: (v) => n.setWatchLinkCloudEnabled(v),
    );
  }

  Widget _watchTransferTile(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) {
    return _tile(
      context,
      icon: Icons.send_outlined,
      title: tr('传递给腕上设备'),
      subtitle: _watchTransferLabel(s),
      trailing: const SizedBox.shrink(),
      onTap: () => _pickWatchTransfer(context, ref, s),
    );
  }

  String _watchTransferLabel(AppSettings? s) {
    final mode = s?.watchLinkTransferMode ?? 'ask';
    if (mode == 'remember') {
      return s?.watchLinkAutoTransfer == true ? tr('自动传递') : tr('不传递');
    }
    return tr('每次询问');
  }

  Widget _watchLinkStatusTile(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) {
    final name = ref.watch(watchLinkConnectedNameProvider);
    final cloudOn = ref.watch(watchLinkCloudOnlineProvider);
    final linkOn = s?.watchLinkageEnabled ?? true;
    final cloudEnabled = s?.watchLinkCloudEnabled ?? true;
    final bt = !linkOn
        ? tr('联动已关闭')
        : name.isNotEmpty
            ? tr('已连接 {name}', {'name': name})
            : tr('未连接');
    final cloud = !cloudEnabled ? tr('未开启') : (cloudOn ? tr('在线') : tr('离线'));
    return _tile(
      context,
      icon: Icons.connect_without_contact,
      title: tr('联动状态'),
      subtitle: tr('蓝牙：{bt} · 云端：{cloud}', {'bt': bt, 'cloud': cloud}),
      trailing: const SizedBox.shrink(),
      showChevron: false,
    );
  }

  Widget _watchDisconnectTile(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) {
    final name = ref.watch(watchLinkConnectedNameProvider);
    final cloudOn = ref.watch(watchLinkCloudOnlineProvider);
    final connected = name.isNotEmpty || cloudOn;
    return _tile(
      context,
      icon: Icons.link_off_outlined,
      title: tr('断开连接'),
      subtitle: connected
          ? tr('断开当前手表连接，手表可随时重新连接')
          : tr('当前无已连接的手表'),
      trailing: const SizedBox.shrink(),
      showChevron: false,
      enabled: connected,
      onTap: connected
          ? () async {
              await ref.read(watchLinkControllerProvider).disconnectWatch();
              if (context.mounted) {
                showXianYuToast(context, tr('已断开手表连接'),
                    duration: const Duration(seconds: 2));
              }
            }
          : null,
    );
  }

  Widget _watchConnectTile(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) {
    final connectedName = ref.watch(watchLinkConnectedNameProvider);
    return _tile(
      context,
      icon: Icons.add_link_outlined,
      title: tr('主动连接手表'),
      subtitle: connectedName.isNotEmpty
          ? tr('已连接 {name}', {'name': connectedName})
          : tr('从已配对设备列表选择手表发起连接'),
      trailing: const SizedBox.shrink(),
      onTap: connectedName.isNotEmpty
          ? null
          : () => _pickWatchToConnect(context, ref, s),
    );
  }

  Future<void> _pickWatchToConnect(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final devs = await ref
        .read(watchLinkControllerProvider)
        .loadPairedDevices()
        .catchError((_) => <WatchBondedDevice>[]);
    if (!context.mounted) return;

    final options = devs
        .where((d) => d.address.isNotEmpty)
        .map((d) => ModernChoiceOption<WatchBondedDevice>(
              label: d.name.isEmpty ? d.address : d.name,
              value: d,
              subtitle: tr('点击连接，手表端需确认'),
            ))
        .toList();

    if (options.isEmpty) {
      final enabled = s?.watchLinkageEnabled ?? true;
      await showModernConfirmDialog(
        context: context,
        title: tr('未发现可连接的手表'),
        message: !enabled
            ? tr('请先开启腕上联动并授予蓝牙权限')
            : tr('请在蓝牙设置中与手表完成配对后重试'),
        isDanger: false,
      );
      return;
    }

    final picked = await showModernChoiceSheet<WatchBondedDevice>(
      context: context,
      title: tr('选择要连接的手表'),
      options: options,
    );
    if (picked == null || !context.mounted) return;
    await ref.read(watchLinkControllerProvider).connectToWatch(picked.address);
    if (context.mounted) {
      showXianYuToast(context, tr('已发起连接，请在手表端确认'),
          duration: const Duration(seconds: 2));
    }
  }

  Widget _watchWakeTile(BuildContext context, WidgetRef ref) {
    return _tile(
      context,
      icon: Icons.ring_volume_outlined,
      title: tr('唤醒手表应用'),
      subtitle: tr('通过华为运动健康远程启动腕上端'),
      trailing: const SizedBox.shrink(),
      showChevron: false,
      onTap: () => _wakeWatchApp(context, ref),
    );
  }

  Future<void> _wakeWatchApp(BuildContext context, WidgetRef ref) async {
    final ctrl = ref.read(watchLinkControllerProvider);
    if (!await ctrl.hasWearEngine()) {
      if (!context.mounted) return;
      final go = await showModernConfirmDialog(
        context: context,
        title: tr('未检测到华为运动健康'),
        message: tr('唤醒腕上端需要华为运动健康提供 Wear Engine 服务，是否前往安装？'),
        isDanger: false,
      );
      if (go && context.mounted) await ctrl.installHealth();
      return;
    }
    if (!context.mounted) return;
    final ok = await showModernConfirmDialog(
      context: context,
      title: tr('同步到手表？'),
      message: tr('将在手表端启动弦予音乐；首次使用需完成 Wear Engine 授权'),
      isDanger: false,
    );
    if (!ok) return;
    final auth = await ctrl.wearAuthorize();
    if (!context.mounted) return;
    if (!auth.granted) {
      showXianYuToast(
        context,
        auth.canceled || auth.message.isEmpty
            ? tr('Wear Engine 授权未完成')
            : tr('Wear Engine 授权失败：{m}', {'m': auth.message}),
        duration: const Duration(seconds: 2),
      );
      return;
    }
    final devs = await ctrl.wearDevices();
    if (!context.mounted) return;
    if (devs.isEmpty) {
      await showModernConfirmDialog(
        context: context,
        title: tr('未检测到已绑定的华为手表'),
        message: tr('远程唤醒仅支持华为手表；Wear OS 手表（三星/OPPO/小米等）请在表上打开弦予音乐，首次打开后将保持常驻，手机播放即可唤起'),
        confirmText: tr('我知道了'),
        isDanger: false,
        icon: Icons.watch_outlined,
      );
      return;
    }
    final msg = await ctrl.wearPing();
    if (context.mounted && msg.isNotEmpty) {
      showXianYuToast(context, msg, duration: const Duration(seconds: 2));
    }
  }

  Widget _watchResetAuthTile(
    BuildContext context,
    AppSettings? s,
    SettingsNotifier n,
  ) {
    final mode = s?.watchLinkTransferMode ?? 'ask';
    final now = DateTime.now();
    final today =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final hasAuth = mode == 'remember' || (s?.watchLinkAskDate == today);
    return _tile(
      context,
      icon: Icons.restart_alt_outlined,
      title: tr('重置联动授权'),
      subtitle: hasAuth
          ? tr('清除记住的选择，恢复每次起播前询问')
          : tr('当前为每次询问，无需重置'),
      trailing: const SizedBox.shrink(),
      showChevron: false,
      enabled: hasAuth,
      onTap: hasAuth ? () async {
        await n.resetWatchLinkAuthorization();
        if (context.mounted) {
          showXianYuToast(context, tr('联动授权已重置'),
              duration: const Duration(seconds: 2));
        }
      } : null,
    );
  }

  Future<void> _pickWatchTransfer(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
  ) async {
    final mode = s?.watchLinkTransferMode ?? 'ask';
    final auto = s?.watchLinkAutoTransfer ?? false;
    final cur = mode == 'remember' ? (auto ? 'auto' : 'none') : 'ask';
    final choice = await showModernChoiceSheet<String>(
      context: context,
      title: tr('传递给腕上设备'),
      options: [
        ModernChoiceOption(
          label: tr('每次询问'),
          value: 'ask',
          subtitle: tr('起播前询问；选「不允许」当天不再询问'),
        ),
        ModernChoiceOption(
          label: tr('自动传递'),
          value: 'auto',
          subtitle: tr('记住选择：直接传递给腕上设备'),
        ),
        ModernChoiceOption(
          label: tr('不传递'),
          value: 'none',
          subtitle: tr('记住选择：不传递到腕上设备'),
        ),
      ],
      currentValue: cur,
    );
    if (choice == null) return;
    final notifier = ref.read(settingsProvider.notifier);
    switch (choice) {
      case 'ask':
        await notifier.setWatchLinkTransferMode('ask');
      case 'auto':
        await notifier.setWatchLinkTransferRemembered(autoTransfer: true);
      case 'none':
        await notifier.setWatchLinkTransferRemembered(autoTransfer: false);
    }
  }
}
