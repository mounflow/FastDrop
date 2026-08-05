import 'package:flutter/material.dart';

class FastDropNavigationBar extends StatelessWidget {
  const FastDropNavigationBar({
    required this.currentIndex,
    super.key,
  });

  final int currentIndex;

  static const _routes = ['/devices', '/transfer', '/settings'];

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      selectedIndex: currentIndex,
      onDestinationSelected: (index) {
        if (index == currentIndex) return;
        Navigator.of(context).pushNamedAndRemoveUntil(
          _routes[index],
          (route) => false,
        );
      },
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.devices_outlined),
          selectedIcon: Icon(Icons.devices_rounded),
          label: '设备',
        ),
        NavigationDestination(
          icon: Icon(Icons.swap_vert_rounded),
          selectedIcon: Icon(Icons.swap_vert_circle_rounded),
          label: '传输',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings_rounded),
          label: '设置',
        ),
      ],
    );
  }
}
