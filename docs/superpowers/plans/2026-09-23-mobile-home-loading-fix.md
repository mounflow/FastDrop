# Mobile Home Loading Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the Android devices home screen from remaining on its loading spinner when Riverpod initialization or device storage loading fails.

**Architecture:** Defer the initial device load until after the first Flutter frame so `ConsumerState.ref` can safely resolve `ProviderScope`. Keep the existing device/connection data flow unchanged, and add a local error state before provider-heavy body rendering so storage failures end loading and expose a retry action.

**Tech Stack:** Flutter, Dart, Riverpod, `flutter_test`, SharedPreferences test mocks, Android ADB

---

## File Map

- Create `fastdrop-mobile/test/features/devices/devices_screen_loading_test.dart`: widget regressions for safe first-frame initialization and failed device loading.
- Modify `fastdrop-mobile/lib/features/devices/devices_screen.dart`: defer startup loading, catch initial load failures, and render retry UI.

### Task 1: Reproduce the startup lifecycle failure

**Files:**
- Create: `fastdrop-mobile/test/features/devices/devices_screen_loading_test.dart`
- Test: `fastdrop-mobile/test/features/devices/devices_screen_loading_test.dart`

- [ ] **Step 1: Write the failing lifecycle test**

Create a controlled store whose load remains pending, then mount `DevicesScreen` inside `ProviderScope`:

```dart
import 'dart:async';

import 'package:fastdrop_mobile/core/providers.dart';
import 'package:fastdrop_mobile/core/storage/session_store.dart';
import 'package:fastdrop_mobile/features/devices/devices_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestDeviceStore extends DeviceStore {
  _TestDeviceStore(this.onLoad);

  final Future<List<Device>> Function() onLoad;

  @override
  Future<List<Device>> loadDevices() => onLoad();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'fastdrop.server_enabled': false,
      'fastdrop.mdns_enabled': false,
    });
  });

  testWidgets('starts device loading after ConsumerState initialization',
      (tester) async {
    final pendingLoad = Completer<List<Device>>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceStoreProvider.overrideWithValue(
            _TestDeviceStore(() => pendingLoad.future),
          ),
        ],
        child: const MaterialApp(home: DevicesScreen()),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run the test and verify RED**

Run from `fastdrop-mobile`:

```powershell
flutter test test/features/devices/devices_screen_loading_test.dart
```

Expected: FAIL because the current `initState()` calls `ref.invalidate(...)` before `ConsumerState` initialization completes; `tester.takeException()` returns the Riverpod inherited-widget exception.

- [ ] **Step 3: Commit the regression test**

```powershell
git add fastdrop-mobile/test/features/devices/devices_screen_loading_test.dart
git commit -m "test(mobile): reproduce devices home startup loading failure"
```

### Task 2: Defer device loading and add failure recovery

**Files:**
- Modify: `fastdrop-mobile/lib/features/devices/devices_screen.dart:604-663`
- Modify: `fastdrop-mobile/lib/features/devices/devices_screen.dart:940-963`
- Test: `fastdrop-mobile/test/features/devices/devices_screen_loading_test.dart`

- [ ] **Step 1: Add the failing storage-error test**

Add a second widget test that returns `Future.error`, pumps the callback, and asserts that loading ends with retry UI:

```dart
testWidgets('shows retry state when paired devices cannot be loaded',
    (tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        deviceStoreProvider.overrideWithValue(
          _TestDeviceStore(
            () => Future<List<Device>>.error(StateError('storage failed')),
          ),
        ),
      ],
      child: const MaterialApp(home: DevicesScreen()),
    ),
  );
  await tester.pump();

  expect(tester.takeException(), isNull);
  expect(find.byType(CircularProgressIndicator), findsNothing);
  expect(find.text('无法加载设备，请重试'), findsOneWidget);
  expect(find.text('重试'), findsOneWidget);
});
```

- [ ] **Step 2: Run the test and verify RED**

```powershell
flutter test test/features/devices/devices_screen_loading_test.dart
```

Expected: FAIL because the current widget has neither deferred loading nor an error/retry state.

- [ ] **Step 3: Implement the minimal lifecycle and error-state fix**

In `_DevicesScreenState`, add `_loadError`, defer the initial call, and limit the `try/catch` to provider/store loading:

```dart
String? _loadError;

@override
void initState() {
  super.initState();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) unawaited(_loadDevices());
  });
}

Future<void> _loadDevices({int preferredIndex = -1}) async {
  late final DeviceStore store;
  late final List<Device> devices;
  try {
    ref.invalidate(localNetworkInfoProvider);
    store = ref.read(deviceStoreProvider);
    devices = await store.loadDevices();
  } catch (error, stackTrace) {
    debugPrint('[Devices] Failed to load paired devices: $error');
    debugPrintStack(stackTrace: stackTrace);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _loadError = '无法加载设备，请重试';
    });
    return;
  }
  if (!mounted) return;

  setState(() {
    _devices = devices;
    _loading = false;
    _loadError = null;
    _rebuildTabController(devices);
  });

  // Keep the existing empty-device and connection flow unchanged below.
}
```

Before watching `fastdropServerProvider` in `_buildBody`, render the recovery state:

```dart
if (_loadError != null) {
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded, size: 42),
          const SizedBox(height: 12),
          Text(_loadError!),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () {
              setState(() {
                _loading = true;
                _loadError = null;
              });
              unawaited(_loadDevices());
            },
            child: const Text('重试'),
          ),
        ],
      ),
    ),
  );
}
```

- [ ] **Step 4: Run focused tests and verify GREEN**

```powershell
flutter test test/features/devices/devices_screen_loading_test.dart
```

Expected: both widget tests PASS with no uncaught Flutter/Riverpod exception.

- [ ] **Step 5: Run formatting and static analysis**

```powershell
dart format lib/features/devices/devices_screen.dart test/features/devices/devices_screen_loading_test.dart
flutter analyze
```

Expected: formatter succeeds and analyzer reports no new errors.

- [ ] **Step 6: Commit the production fix**

```powershell
git add fastdrop-mobile/lib/features/devices/devices_screen.dart fastdrop-mobile/test/features/devices/devices_screen_loading_test.dart
git commit -m "fix(mobile): stop devices home loading loop"
```

### Task 3: Build, install, and verify on the connected phone

**Files:**
- Build output: `fastdrop-mobile/build/app/outputs/flutter-apk/app-debug.apk`

- [ ] **Step 1: Run the relevant mobile test suite**

```powershell
flutter test test/features/devices test/core/providers_test.dart test/core/network/local_network_info_test.dart
```

Expected: all selected tests PASS.

- [ ] **Step 2: Build the Android debug APK**

```powershell
flutter build apk --debug --target-platform android-arm64 --android-skip-build-dependency-validation --no-pub
```

Expected: `Built build\app\outputs\flutter-apk\app-debug.apk`.

- [ ] **Step 3: Install and launch on the connected phone**

```powershell
$adb = 'D:\Tools\AboutCode\AndroidStudio\Sdk\platform-tools\adb.exe'
& $adb -s 10AD6S0Z9M0011G install -r build\app\outputs\flutter-apk\app-debug.apk
& $adb -s 10AD6S0Z9M0011G shell am force-stop com.fastdrop.fastdrop_mobile
& $adb -s 10AD6S0Z9M0011G logcat -c
& $adb -s 10AD6S0Z9M0011G shell am start -n com.fastdrop.fastdrop_mobile/.MainActivity
```

Expected: install returns `Success` and the main activity starts.

- [ ] **Step 4: Verify the real-device result**

After allowing eight seconds for initialization, capture a screenshot and filter process logs.

Expected:

- The devices home page no longer shows the full-screen loading spinner.
- Logs contain no `dependOnInheritedWidgetOfExactType<UncontrolledProviderScope>()` exception.
- mDNS/server startup may continue independently without blocking the home page.

