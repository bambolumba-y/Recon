# Recon Stage 1: multi-subscription auto group (Dart-side merge) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A buildable Recon fork of Hiddify where the user marks subscriptions as members of one auto group, the app merges their servers into one sing-box config, the existing `lowest-delay` balancer picks a live server, and Remnawave panels serve real servers because the app sends HWID headers.

**Architecture:** Each subscription is already parsed by the Go core into a flat sing-box JSON file (`<workingDir>/configs/<profileId>.json`). Stage 1 adds a Dart merge layer that concatenates the `outbounds`/`endpoints` of all member profiles into `configs/auto-group.json` (tags prefixed with the subscription name), validates it through the core `Parse()` call, and starts the core on that file instead of the active profile's file. The Go core is the prebuilt Hiddify 4.1.0 AAR; no Go toolchain in this stage.

**Tech Stack:** Flutter 3.38.5 / Dart ^3.10.4, hooks_riverpod 2 with riverpod_annotation codegen, freezed 2, drift 2.21 (step-by-step migrations), slang 4 for i18n, fpdart TaskEither, dio 5, flutter_test. Android SDK 36, JDK 21 local (Gradle 8.7, AGP 8.6, Kotlin 2.1), GitHub Actions for CI builds.

**Spec:** `C:/Users/bambolumba/Desktop/Recon/docs/superpowers/specs/2026-09-12-hiddify-multi-sub-failover-design.md` (sections 4 and 6 are Stage 1).

## Global Constraints

- Repository: local clone at `C:/Users/bambolumba/Desktop/Recon/hiddify-app`, branch `recon/main` cut from tag `v4.1.2`. Public GitHub fork `bambolumba-y/Recon`, created as a fork of `hiddify/hiddify-app` (license condition 1).
- Core: prebuilt `hiddify-lib-android.tar.gz` from `https://github.com/hiddify/hiddify-core/releases/download/v4.1.0/` (`dependencies.properties` says `core.version=4.1.0`). Do not modify `hiddify-core` in this stage.
- UI constraint from the owner: stay within the original Hiddify design. Reuse existing widgets (`Card` with `ProfileTileConst.cardBorderRadius`, `AdaptiveMenuItem`, `SwitchListTile.adaptive`, theme colours, `Gap`), no new colours, fonts or icon sets. New strings go through slang (`assets/translations/en.i18n.json` base, `ru.i18n.json` too; other locales fall back to English via `fallback_strategy: base_locale`).
- Formatting: `dart format` with `page_width: 120` (from `analysis_options.yaml`). Run `dart format lib test` before each commit.
- Codegen after touching annotated files: `dart run build_runner build --delete-conflicting-outputs`; after touching translations: `dart run slang`.
- Commit messages follow the Recon project convention: `feat(scope): summary in Russian`, `fix(...)`, `chore(...)`, ending with the attribution trailer lines given by the session.
- All tests: `flutter test` from the repo root. Flutter binary lives at `C:/src/flutter/bin/flutter` after Task 1; in Git Bash use `/c/src/flutter/bin/flutter` and `/c/src/flutter/bin/dart` explicitly (PATH changes made with `setx` do not reach an already open shell).
- Subagent tasks: think and write in English; no Playwright/device self-verification claims; the device test in Task 10 is executed by the owner with the main session.
- Do not commit `android/app/libs/` (already ignored upstream; verify with `git check-ignore android/app/libs` before the first commit).

---

## File structure

New files (all under `hiddify-app/`):

| Path | Responsibility |
|---|---|
| `lib/core/device_identity/device_identity.dart` | `DeviceIdentity` value object + Remnawave HWID header map |
| `lib/core/device_identity/device_identity_provider.dart` | Riverpod provider that creates/stores the per-install HWID in SharedPreferences |
| `lib/features/auto_group/data/auto_group_merger.dart` | Pure function: N parsed profile configs -> one merged config + provenance + warnings |
| `lib/features/auto_group/data/auto_group_repository.dart` | Reads member profiles, runs the merger, validates via core, writes `auto-group.json` and `auto-group.meta.json` |
| `lib/features/auto_group/data/auto_group_data_providers.dart` | Provider wiring for the repository |
| `lib/features/auto_group/model/auto_group_failure.dart` | Sealed failure type for merge/build errors |
| `lib/features/auto_group/notifier/auto_group_notifier.dart` | Members stream, enabled preference, last build info, membership toggle |
| `lib/features/auto_group/widget/auto_group_card.dart` | Home-screen card: switch, counts, warnings |
| `test/core/device_identity/device_identity_test.dart` | Header map test |
| `test/features/auto_group/data/auto_group_merger_test.dart` | Merger unit tests |
| `test/features/profile/data/profile_dao_auto_group_test.dart` | DAO test with in-memory database |
| `.github/workflows/recon-android.yml` | CI: build unsigned release APK, upload artifact |

Modified files:

| Path | Change |
|---|---|
| `lib/core/http_client/dio_http_client.dart` | `headers` parameter on `get`/`download` |
| `lib/features/profile/data/profile_parser.dart` | send HWID headers on subscription download |
| `lib/core/db/db.dart`, `lib/core/db/db.steps.dart`, `lib/core/db/schemas/db/drift_schema_v7.json`, `test/drift/db/generated/*` | schema v7: `include_in_auto` column |
| `lib/features/profile/data/profile_data_source.dart` | `watchAutoGroupMembers()`, `setIncludeInAuto()` |
| `lib/features/profile/model/profile_entity.dart`, `lib/features/profile/data/profile_data_mapper.dart` | `includeInAuto` field |
| `lib/features/profile/data/profile_repository.dart` | pass-through methods |
| `lib/core/preferences/general_preferences.dart` | `autoGroupEnabled` preference |
| `lib/features/connection/data/connection_repository.dart` | `connectAutoGroup` / `reconnectAutoGroup` |
| `lib/features/connection/notifier/connection_notifier.dart` | mode switch + reconnect triggers |
| `lib/features/profile/widget/profile_tile.dart` | menu item + membership marker |
| `lib/features/home/widget/home_page.dart` | show `AutoGroupCard` |
| `assets/translations/en.i18n.json`, `assets/translations/ru.i18n.json` | new strings, app title |
| `android/app/src/main/AndroidManifest.xml` | app label |

---

### Task 1: Fork, branch, toolchain, baseline build

**Files:**
- Modify: git remotes of `C:/Users/bambolumba/Desktop/Recon/hiddify-app`
- Create: `C:/src/flutter` (Flutter SDK checkout)
- Create: `hiddify-app/android/app/libs/` (downloaded core, git-ignored)
- Create: `hiddify-app/docs/superpowers/specs/2026-09-12-hiddify-multi-sub-failover-design.md`, `hiddify-app/docs/superpowers/plans/2026-09-12-recon-stage1-multi-sub-merge.md` (copies of the Recon docs so the spec travels with the fork)

**Interfaces:**
- Produces: a working `flutter build apk` on `recon/main`; every later task assumes this environment.

- [ ] **Step 1: Unshallow the clone and cut the branch from the release tag**

```bash
cd /c/Users/bambolumba/Desktop/Recon/hiddify-app
git fetch --unshallow origin
git fetch --tags origin
git checkout -b recon/main v4.1.2
git log -1 --format='%h %ci %s'
```
Expected: HEAD is the commit tagged `v4.1.2` (2026-03-05).

- [ ] **Step 2: Create the public fork on GitHub and add it as a remote**

```bash
gh repo fork hiddify/hiddify-app --fork-name Recon --clone=false --remote=false
git remote add recon https://github.com/bambolumba-y/Recon.git
git remote -v
```
Expected: `recon` remote listed; `gh repo view bambolumba-y/Recon --json isFork,parent` prints `"isFork": true` with parent `hiddify/hiddify-app`.

- [ ] **Step 3: Install Flutter 3.38.5**

```bash
mkdir -p /c/src
git clone https://github.com/flutter/flutter.git -b 3.38.5 --depth 1 /c/src/flutter
/c/src/flutter/bin/flutter --version
/c/src/flutter/bin/flutter config --android-sdk "$LOCALAPPDATA/Android/Sdk" --no-analytics
yes | /c/src/flutter/bin/flutter doctor --android-licenses
/c/src/flutter/bin/flutter doctor -v
```
Expected: `Flutter 3.38.5`, Dart `3.10.x`; doctor shows Android toolchain OK (cmdline-tools, licenses accepted), Java 21 detected. Missing Chrome/VS Code entries are fine. Then persist PATH for future shells (PowerShell):
```powershell
[Environment]::SetEnvironmentVariable("Path", [Environment]::GetEnvironmentVariable("Path","User") + ";C:\src\flutter\bin", "User")
```

- [ ] **Step 4: Download the prebuilt core and run codegen**

```bash
cd /c/Users/bambolumba/Desktop/Recon/hiddify-app
mkdir -p android/app/libs
curl -L https://github.com/hiddify/hiddify-core/releases/download/v4.1.0/hiddify-lib-android.tar.gz | tar xz -C android/app/libs/
ls -la android/app/libs
git check-ignore android/app/libs && echo "libs ignored"
/c/src/flutter/bin/flutter pub get
/c/src/flutter/bin/dart run build_runner build --delete-conflicting-outputs
/c/src/flutter/bin/dart run slang
```
Expected: `android/app/libs/` contains `hiddify-lib.aar` (name may include `libcore`), git reports it ignored, codegen ends with `Succeeded`.

- [ ] **Step 5: Baseline test run and debug build**

```bash
/c/src/flutter/bin/flutter test
/c/src/flutter/bin/flutter build apk --debug --target-platform android-arm64
ls build/app/outputs/flutter-apk/
```
Expected: all upstream tests pass; `app-arm64-v8a-debug.apk` (and possibly `app-debug.apk`) exist. If Gradle fails on JDK 21, set `org.gradle.java.home` in `android/gradle.properties` to a JDK 17 path and retry.

- [ ] **Step 6: Copy the Recon docs into the fork and commit**

```bash
mkdir -p docs/superpowers/specs docs/superpowers/plans
cp ../docs/superpowers/specs/2026-09-12-hiddify-multi-sub-failover-design.md docs/superpowers/specs/
cp ../docs/superpowers/plans/2026-09-12-recon-stage1-multi-sub-merge.md docs/superpowers/plans/
git add docs/superpowers
git commit -m "docs(recon): спека и план этапа 1 объединённого автовыбора"
git push -u recon recon/main
```
Expected: branch visible at `https://github.com/bambolumba-y/Recon/tree/recon/main`.

---

### Task 2: HWID headers for subscription downloads

**Files:**
- Create: `lib/core/device_identity/device_identity.dart`
- Create: `lib/core/device_identity/device_identity_provider.dart`
- Modify: `lib/core/http_client/dio_http_client.dart:86-152`
- Modify: `lib/features/profile/data/profile_parser.dart:151-185` and `:186-243`
- Test: `test/core/device_identity/device_identity_test.dart`

**Interfaces:**
- Produces: `DeviceIdentity({required String hwid, required String os, required String osVersion, required String model})` with `Map<String, String> toSubscriptionHeaders()`; provider `deviceIdentityProvider` (`DeviceIdentity`, keepAlive); `DioHttpClient.download(..., Map<String, String>? headers)` and `get(..., Map<String, String>? headers)`.

- [ ] **Step 1: Write the failing test**

`test/core/device_identity/device_identity_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/device_identity/device_identity.dart';

void main() {
  group('DeviceIdentity', () {
    test('produces the four Remnawave headers', () {
      const identity = DeviceIdentity(hwid: 'abc-123', os: 'Android', osVersion: '14', model: 'Recon');
      final headers = identity.toSubscriptionHeaders();
      expect(headers, {
        'x-hwid': 'abc-123',
        'x-device-os': 'Android',
        'x-ver-os': '14',
        'x-device-model': 'Recon',
      });
    });

    test('normalises the platform name', () {
      expect(DeviceIdentity.osNameFor('android'), 'Android');
      expect(DeviceIdentity.osNameFor('ios'), 'iOS');
      expect(DeviceIdentity.osNameFor('windows'), 'Windows');
      expect(DeviceIdentity.osNameFor('linux'), 'Linux');
      expect(DeviceIdentity.osNameFor('macos'), 'macOS');
      expect(DeviceIdentity.osNameFor('fuchsia'), 'fuchsia');
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `/c/src/flutter/bin/flutter test test/core/device_identity/device_identity_test.dart`
Expected: compile error, `device_identity.dart` not found.

- [ ] **Step 3: Implement `DeviceIdentity`**

`lib/core/device_identity/device_identity.dart`:
```dart
/// Per-install device identity sent to subscription panels (Remnawave, Marzban)
/// that enforce a device limit. Without these headers such panels answer with a
/// stub "App not supported" server instead of the real list.
class DeviceIdentity {
  const DeviceIdentity({required this.hwid, required this.os, required this.osVersion, required this.model});

  /// Stable random id generated once per installation.
  final String hwid;
  final String os;
  final String osVersion;
  final String model;

  static const String hwidHeader = 'x-hwid';
  static const String osHeader = 'x-device-os';
  static const String osVersionHeader = 'x-ver-os';
  static const String modelHeader = 'x-device-model';

  Map<String, String> toSubscriptionHeaders() => {
    hwidHeader: hwid,
    osHeader: os,
    osVersionHeader: osVersion,
    modelHeader: model,
  };

  static String osNameFor(String operatingSystem) => switch (operatingSystem) {
    'android' => 'Android',
    'ios' => 'iOS',
    'windows' => 'Windows',
    'linux' => 'Linux',
    'macos' => 'macOS',
    _ => operatingSystem,
  };
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `/c/src/flutter/bin/flutter test test/core/device_identity/device_identity_test.dart`
Expected: 2 tests pass.

- [ ] **Step 5: Add the provider that persists the HWID**

`lib/core/device_identity/device_identity_provider.dart`:
```dart
import 'dart:io';

import 'package:hiddify/core/device_identity/device_identity.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';

part 'device_identity_provider.g.dart';

const String _hwidPrefKey = 'device_hwid';
const String _deviceModel = 'Recon';

@Riverpod(keepAlive: true)
DeviceIdentity deviceIdentity(Ref ref) {
  final prefs = ref.watch(sharedPreferencesProvider).requireValue;
  var hwid = prefs.getString(_hwidPrefKey);
  if (hwid == null || hwid.isEmpty) {
    hwid = const Uuid().v4();
    // fire and forget: the value is already in memory for this run
    prefs.setString(_hwidPrefKey, hwid);
  }
  return DeviceIdentity(
    hwid: hwid,
    os: DeviceIdentity.osNameFor(Platform.operatingSystem),
    osVersion: Platform.operatingSystemVersion,
    model: _deviceModel,
  );
}
```
`sharedPreferencesProvider` is `Future<SharedPreferences>`; it is awaited at app bootstrap in upstream (`requireValue` is used the same way in `general_preferences.dart:124`).

- [ ] **Step 6: Add a `headers` parameter to the HTTP client**

In `lib/core/http_client/dio_http_client.dart` change `get`, `download` and `_options`:
```dart
  Future<Response<T>> get<T>(
    String url, {
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    bool proxyOnly = false,
    Map<String, String>? headers,
  }) async {
    final mode = proxyOnly
        ? "proxy"
        : await isPortOpen("127.0.0.1", port)
        ? "both"
        : "direct";
    final dio = _dio[mode]!;

    return dio.get<T>(
      url,
      cancelToken: cancelToken,
      options: _options(url, userAgent: userAgent, credentials: credentials, headers: headers),
    );
  }

  Future<Response> download(
    String url,
    String path, {
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    bool proxyOnly = false,
    Map<String, String>? headers,
  }) async {
    final mode = proxyOnly
        ? "proxy"
        : await isPortOpen("127.0.0.1", port)
        ? "both"
        : "direct";
    final dio = _dio[mode]!;
    return dio.download(
      url,
      path,
      cancelToken: cancelToken,
      options: _options(url, userAgent: userAgent, credentials: credentials, headers: headers),
    );
  }

  Options _options(
    String url, {
    String? userAgent,
    ({String username, String password})? credentials,
    Map<String, String>? headers,
  }) {
    final uri = Uri.parse(url);

    String? userInfo;
    if (credentials != null) {
      userInfo = "${credentials.username}:${credentials.password}";
    } else if (uri.userInfo.isNotEmpty) {
      userInfo = uri.userInfo;
    }

    String? basicAuth;
    if (userInfo != null) {
      basicAuth = "Basic ${base64.encode(utf8.encode(userInfo))}";
    }

    return Options(
      headers: {
        if (userAgent != null) "User-Agent": userAgent,
        if (basicAuth != null) "authorization": basicAuth,
        ...?headers,
      },
    );
  }
```

- [ ] **Step 7: Send the headers from the profile parser**

In `lib/features/profile/data/profile_parser.dart` add the import
`import 'package:hiddify/core/device_identity/device_identity_provider.dart';` and change the two download calls. In `_downloadProfile` (line ~159):
```dart
    final deviceHeaders = _ref.read(deviceIdentityProvider).toSubscriptionHeaders();
    final rs = await _httpClient
        .download(
          url.trim(),
          tempFilePath,
          cancelToken: cancelToken,
          userAgent: _ref.read(ConfigOptions.useXrayCoreWhenPossible)
              ? _httpClient.userAgent.replaceAll("HiddifyNext", "HiddifyNextX")
              : null,
          headers: deviceHeaders,
        )
```
In `expandRemoteLinesInParallel` (line ~218):
```dart
          await httpClient.download(
            line,
            tmpPath,
            cancelToken: cancelToken,
            userAgent: ref.read(ConfigOptions.useXrayCoreWhenPossible)
                ? httpClient.userAgent.replaceAll('HiddifyNext', 'HiddifyNextX')
                : null,
            headers: ref.read(deviceIdentityProvider).toSubscriptionHeaders(),
          );
```

- [ ] **Step 8: Codegen, analyze, full test run**

```bash
/c/src/flutter/bin/dart run build_runner build --delete-conflicting-outputs
/c/src/flutter/bin/dart format lib test
/c/src/flutter/bin/flutter analyze lib/core/device_identity lib/core/http_client lib/features/profile/data
/c/src/flutter/bin/flutter test
```
Expected: no new analyzer errors, all tests pass.

- [ ] **Step 9: Commit**

```bash
git add lib/core/device_identity lib/core/http_client/dio_http_client.dart lib/features/profile/data/profile_parser.dart test/core/device_identity
git commit -m "feat(subscriptions): HWID-заголовки Remnawave при загрузке подписок"
```

---

### Task 3: Database column `include_in_auto` (schema v7) and DAO methods

**Files:**
- Modify: `lib/core/db/db.dart:17,65-67,79-98`
- Regenerate: `lib/core/db/db.steps.dart`, `lib/core/db/schemas/db/drift_schema_v7.json`, `test/drift/db/generated/schema.dart`, `test/drift/db/generated/schema_v7.dart`
- Modify: `lib/features/profile/data/profile_data_source.dart`
- Test: `test/drift/db/migration_test.dart` (existing, loops over all versions), `test/features/profile/data/profile_dao_auto_group_test.dart`

**Interfaces:**
- Produces: column `ProfileEntries.includeInAuto` (`bool`, default false); `ProfileDataSource.watchAutoGroupMembers(): Stream<List<ProfileEntry>>`; `ProfileDataSource.setIncludeInAuto(String id, bool value): Future<void>`.

- [ ] **Step 1: Write the failing DAO test**

`test/features/profile/data/profile_dao_auto_group_test.dart`:
```dart
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/features/profile/data/profile_data_source.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';

void main() {
  late Db db;
  late ProfileDao dao;

  ProfileEntriesCompanion entry(String id, String name, {bool active = false}) => ProfileEntriesCompanion.insert(
    id: id,
    type: ProfileType.remote,
    active: active,
    name: name,
    url: Value('https://example.com/$id'),
    lastUpdate: DateTime(2026, 9, 12),
  );

  setUp(() {
    db = Db(NativeDatabase.memory());
    dao = ProfileDao(db);
  });

  tearDown(() => db.close());

  test('new profiles are not in the auto group', () async {
    await dao.insert(entry('a', 'A', active: true));
    final row = await dao.getById('a');
    expect(row!.includeInAuto, isFalse);
    expect(await dao.watchAutoGroupMembers().first, isEmpty);
  });

  test('setIncludeInAuto toggles membership without touching active', () async {
    await dao.insert(entry('a', 'A', active: true));
    await dao.insert(entry('b', 'B'));
    await dao.setIncludeInAuto('b', true);

    final members = await dao.watchAutoGroupMembers().first;
    expect(members.map((e) => e.id), ['b']);
    expect((await dao.getById('a'))!.active, isTrue);

    await dao.setIncludeInAuto('b', false);
    expect(await dao.watchAutoGroupMembers().first, isEmpty);
  });

  test('members are ordered by name', () async {
    await dao.insert(entry('z', 'Zeta'));
    await dao.insert(entry('m', 'Mid'));
    await dao.setIncludeInAuto('z', true);
    await dao.setIncludeInAuto('m', true);
    final members = await dao.watchAutoGroupMembers().first;
    expect(members.map((e) => e.name), ['Mid', 'Zeta']);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `/c/src/flutter/bin/flutter test test/features/profile/data/profile_dao_auto_group_test.dart`
Expected: compile error, `includeInAuto` / `watchAutoGroupMembers` undefined.

- [ ] **Step 3: Add the column and the migration step**

In `lib/core/db/db.dart`:
```dart
  @override
  int get schemaVersion => 7;
```
add after `from5To6`:
```dart
        from6To7: (m, schema) async {
          await m.addColumn(schema.profileEntries, schema.profileEntries.includeInAuto);
        },
```
and in `ProfileEntries` after `userOverride`:
```dart
  BoolColumn get includeInAuto => boolean().withDefault(const Constant(false))();
```

- [ ] **Step 4: Regenerate schema artefacts**

```bash
/c/src/flutter/bin/dart run drift_dev make-migrations
```
`build.yaml` already points `make-migrations` at `lib/core/db/db.dart` with `schema_dir: lib/core/db/schemas`. Expected: new `lib/core/db/schemas/db/drift_schema_v7.json`, updated `lib/core/db/db.steps.dart` containing `from6To7` and `Schema7`, updated `test/drift/db/generated/schema.dart` and new `schema_v7.dart`.
If `make-migrations` is unavailable in the pinned drift_dev, run the three explicit commands instead:
```bash
/c/src/flutter/bin/dart run drift_dev schema dump lib/core/db/db.dart lib/core/db/schemas/db/
/c/src/flutter/bin/dart run drift_dev schema steps lib/core/db/schemas/db/ lib/core/db/db.steps.dart
/c/src/flutter/bin/dart run drift_dev schema generate lib/core/db/schemas/db/ test/drift/db/generated/
```
Then:
```bash
/c/src/flutter/bin/dart run build_runner build --delete-conflicting-outputs
```

- [ ] **Step 5: Add DAO methods**

In `lib/features/profile/data/profile_data_source.dart` extend the interface:
```dart
  Stream<List<ProfileEntry>> watchAutoGroupMembers();
  Future<void> setIncludeInAuto(String id, bool value);
```
and the implementation inside `ProfileDao`:
```dart
  @override
  Stream<List<ProfileEntry>> watchAutoGroupMembers() {
    return (profileEntries.select()
          ..where((tbl) => tbl.includeInAuto.equals(true))
          ..orderBy([(tbl) => OrderingTerm(expression: tbl.name, mode: OrderingMode.asc)]))
        .watch();
  }

  @override
  Future<void> setIncludeInAuto(String id, bool value) async {
    await (update(profileEntries)..where((tbl) => tbl.id.equals(id))).write(
      ProfileEntriesCompanion(includeInAuto: Value(value)),
    );
  }
```

- [ ] **Step 6: Run the DAO test and the migration tests**

Run: `/c/src/flutter/bin/flutter test test/features/profile/data/profile_dao_auto_group_test.dart test/drift/db/migration_test.dart`
Expected: all pass, including the generated `from 6 -> to 7` case.

- [ ] **Step 7: Commit**

```bash
/c/src/flutter/bin/dart format lib test
git add lib/core/db lib/features/profile/data/profile_data_source.dart test/drift test/features/profile/data/profile_dao_auto_group_test.dart
git commit -m "feat(db): флаг include_in_auto у подписок, схема v7"
```

---

### Task 4: `includeInAuto` on the profile entity and repository pass-through

**Files:**
- Modify: `lib/features/profile/model/profile_entity.dart:17-36`
- Modify: `lib/features/profile/data/profile_data_mapper.dart`
- Modify: `lib/features/profile/data/profile_repository.dart`
- Test: `test/features/profile/data/profile_data_mapper_test.dart` (new)

**Interfaces:**
- Produces: `ProfileEntity.includeInAuto` (`bool`, default false) on both variants; `ProfileRepository.watchAutoGroupMembers(): Stream<Either<ProfileFailure, List<ProfileEntity>>>`; `ProfileRepository.setIncludeInAuto(String id, bool value): TaskEither<ProfileFailure, Unit>`.

- [ ] **Step 1: Write the failing mapper test**

`test/features/profile/data/profile_data_mapper_test.dart`:
```dart
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/features/profile/data/profile_data_mapper.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';

void main() {
  test('entry -> entity carries includeInAuto', () {
    final entry = ProfileEntry(
      id: 'a',
      type: ProfileType.remote,
      active: false,
      name: 'A',
      url: 'https://example.com/a',
      lastUpdate: DateTime(2026, 9, 12),
      includeInAuto: true,
    );
    expect(entry.toEntity().includeInAuto, isTrue);
  });

  test('insert entry keeps includeInAuto, update entry leaves it untouched', () {
    final entity = ProfileEntity.remote(
      id: 'a',
      active: false,
      name: 'A',
      url: 'https://example.com/a',
      lastUpdate: DateTime(2026, 9, 12),
      includeInAuto: true,
    );
    expect(entity.toInsertEntry().includeInAuto, const Value(true));
    expect(entity.toUpdateEntry().includeInAuto.present, isFalse);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `/c/src/flutter/bin/flutter test test/features/profile/data/profile_data_mapper_test.dart`
Expected: compile error, `includeInAuto` is not a named parameter of `ProfileEntity.remote`.

- [ ] **Step 3: Add the field to the entity**

In `lib/features/profile/model/profile_entity.dart` add `@Default(false) bool includeInAuto,` to both factories:
```dart
  const factory ProfileEntity.remote({
    required String id,
    required bool active,
    required String name,
    required String url,
    required DateTime lastUpdate,
    ProfileOptions? options,
    SubscriptionInfo? subInfo,
    Map<String, dynamic>? populatedHeaders,
    UserOverride? userOverride,
    @Default(false) bool includeInAuto,
  }) = RemoteProfileEntity;

  const factory ProfileEntity.local({
    required String id,
    required bool active,
    required String name,
    required DateTime lastUpdate,
    Map<String, dynamic>? populatedHeaders,
    UserOverride? userOverride,
    @Default(false) bool includeInAuto,
  }) = LocalProfileEntity;
```

- [ ] **Step 4: Map the field**

In `lib/features/profile/data/profile_data_mapper.dart`, `toInsertEntry`: add `includeInAuto: Value(rp.includeInAuto),` to the remote branch and `includeInAuto: Value(lp.includeInAuto),` to the local branch. Leave `toUpdateEntry` unchanged (a subscription refresh must not reset membership). In `toEntity` add `includeInAuto: includeInAuto,` to both constructors.

- [ ] **Step 5: Repository pass-through**

In `lib/features/profile/data/profile_repository.dart` add to the interface:
```dart
  Stream<Either<ProfileFailure, List<ProfileEntity>>> watchAutoGroupMembers();
  TaskEither<ProfileFailure, Unit> setIncludeInAuto(String id, bool value);
```
and to `ProfileRepositoryImpl`:
```dart
  @override
  Stream<Either<ProfileFailure, List<ProfileEntity>>> watchAutoGroupMembers() {
    return _profileDataSource
        .watchAutoGroupMembers()
        .map((event) => event.map((e) => e.toEntity()).toList())
        .handleExceptions(ProfileUnexpectedFailure.new);
  }

  @override
  TaskEither<ProfileFailure, Unit> setIncludeInAuto(String id, bool value) {
    return TaskEither.tryCatch(() async {
      await _profileDataSource.setIncludeInAuto(id, value);
      return unit;
    }, ProfileUnexpectedFailure.new);
  }
```

- [ ] **Step 6: Codegen and tests**

```bash
/c/src/flutter/bin/dart run build_runner build --delete-conflicting-outputs
/c/src/flutter/bin/flutter test
```
Expected: mapper test and all existing tests pass (existing `ProfileEntity.remote(...)` call sites compile because the new field has a default).

- [ ] **Step 7: Commit**

```bash
/c/src/flutter/bin/dart format lib test
git add lib/features/profile test/features/profile/data/profile_data_mapper_test.dart
git commit -m "feat(profiles): поле includeInAuto в сущности и репозитории"
```

---

### Task 5: Pure merger

**Files:**
- Create: `lib/features/auto_group/data/auto_group_merger.dart`
- Test: `test/features/auto_group/data/auto_group_merger_test.dart`

**Interfaces:**
- Produces:
```dart
class AutoGroupSource { final String profileId; final String profileName; final Map<String, dynamic> config; }
class AutoGroupTagOrigin { final String profileId; final String profileName; final String originalTag; }
class AutoGroupMergeResult {
  final Map<String, dynamic> config;            // {"outbounds": [...], "endpoints": [...]}
  final Map<String, AutoGroupTagOrigin> origins; // merged tag -> where it came from
  final List<String> warnings;
  int get serverCount;
}
class AutoGroupMerger { static AutoGroupMergeResult merge(List<AutoGroupSource> sources); static String prefixFor(String profileName); }
```

- [ ] **Step 1: Write the failing tests**

`test/features/auto_group/data/auto_group_merger_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/auto_group/data/auto_group_merger.dart';

Map<String, dynamic> vless(String tag, String server, {String? detour}) => {
  'type': 'vless',
  'tag': tag,
  'server': server,
  'server_port': 443,
  'uuid': '00000000-0000-0000-0000-000000000000',
  if (detour != null) 'detour': detour,
};

AutoGroupSource source(String id, String name, List<Map<String, dynamic>> outbounds, {List<Map<String, dynamic>>? endpoints}) =>
    AutoGroupSource(profileId: id, profileName: name, config: {
      'outbounds': outbounds,
      if (endpoints != null) 'endpoints': endpoints,
    });

void main() {
  group('AutoGroupMerger.merge', () {
    test('prefixes tags with the profile name and records origins', () {
      final result = AutoGroupMerger.merge([
        source('p1', 'Alpha', [vless('NL-1', 'nl.example.com')]),
        source('p2', 'Beta', [vless('NL-1', 'nl2.example.com')]),
      ]);
      final tags = (result.config['outbounds'] as List).map((e) => (e as Map)['tag']).toList();
      expect(tags, ['Alpha · NL-1', 'Beta · NL-1']);
      expect(result.origins['Alpha · NL-1']!.profileId, 'p1');
      expect(result.origins['Beta · NL-1']!.originalTag, 'NL-1');
      expect(result.serverCount, 2);
      expect(result.warnings, isEmpty);
    });

    test('rewrites detour references inside the same profile', () {
      final result = AutoGroupMerger.merge([
        source('p1', 'Alpha', [vless('front', 'a.example.com'), vless('chained', 'b.example.com', detour: 'front')]),
      ]);
      final outbounds = (result.config['outbounds'] as List).cast<Map>();
      expect(outbounds[1]['detour'], 'Alpha · front');
    });

    test('drops group outbounds and reserved tags', () {
      final result = AutoGroupMerger.merge([
        source('p1', 'Alpha', [
          {'type': 'selector', 'tag': 'select', 'outbounds': ['auto', 'NL-1']},
          {'type': 'urltest', 'tag': 'auto', 'outbounds': ['NL-1']},
          {'type': 'balancer', 'tag': 'lowest', 'outbounds': ['NL-1']},
          {'type': 'direct', 'tag': 'direct'},
          {'type': 'block', 'tag': 'block'},
          {'type': 'dns', 'tag': 'dns-out'},
          vless('NL-1', 'nl.example.com'),
        ]),
      ]);
      final tags = (result.config['outbounds'] as List).map((e) => (e as Map)['tag']).toList();
      expect(tags, ['Alpha · NL-1']);
    });

    test('deduplicates identical servers across profiles and warns', () {
      final result = AutoGroupMerger.merge([
        source('p1', 'Alpha', [vless('NL-1', 'same.example.com')]),
        source('p2', 'Beta', [vless('Netherlands', 'same.example.com')]),
      ]);
      expect(result.serverCount, 1);
      expect(result.warnings.single, contains('Beta · Netherlands'));
    });

    test('keeps endpoints and prefixes them too', () {
      final result = AutoGroupMerger.merge([
        source('p1', 'Alpha', [], endpoints: [
          {'type': 'wireguard', 'tag': 'wg', 'address': ['10.0.0.2/32'], 'private_key': 'x', 'peers': []},
        ]),
      ]);
      final endpoints = (result.config['endpoints'] as List).cast<Map>();
      expect(endpoints.single['tag'], 'Alpha · wg');
      expect(result.serverCount, 1);
    });

    test('profile without servers produces a warning and is skipped', () {
      final result = AutoGroupMerger.merge([
        source('p1', 'Empty', []),
        source('p2', 'Alpha', [vless('NL-1', 'nl.example.com')]),
      ]);
      expect(result.serverCount, 1);
      expect(result.warnings.single, contains('Empty'));
    });

    test('empty input yields zero servers', () {
      final result = AutoGroupMerger.merge([]);
      expect(result.serverCount, 0);
      expect(result.config['outbounds'], isEmpty);
    });

    test('duplicate profile names get numeric suffixes', () {
      final result = AutoGroupMerger.merge([
        source('p1', 'Sub', [vless('A', 'a.example.com')]),
        source('p2', 'Sub', [vless('A', 'b.example.com')]),
      ]);
      final tags = (result.config['outbounds'] as List).map((e) => (e as Map)['tag']).toList();
      expect(tags, ['Sub · A', 'Sub 2 · A']);
    });
  });

  test('prefixFor collapses whitespace and truncates to 12 characters', () {
    expect(AutoGroupMerger.prefixFor('  My   very long subscription name '), 'My very long');
    expect(AutoGroupMerger.prefixFor(''), 'Sub');
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `/c/src/flutter/bin/flutter test test/features/auto_group/data/auto_group_merger_test.dart`
Expected: compile error, file not found.

- [ ] **Step 3: Implement the merger**

`lib/features/auto_group/data/auto_group_merger.dart`:
```dart
import 'dart:convert';

/// One member profile's parsed sing-box config (the file the core wrote after `Parse()`).
class AutoGroupSource {
  const AutoGroupSource({required this.profileId, required this.profileName, required this.config});

  final String profileId;
  final String profileName;
  final Map<String, dynamic> config;
}

class AutoGroupTagOrigin {
  const AutoGroupTagOrigin({required this.profileId, required this.profileName, required this.originalTag});

  final String profileId;
  final String profileName;
  final String originalTag;

  Map<String, dynamic> toJson() => {'profileId': profileId, 'profileName': profileName, 'originalTag': originalTag};
}

class AutoGroupMergeResult {
  const AutoGroupMergeResult({required this.config, required this.origins, required this.warnings});

  final Map<String, dynamic> config;
  final Map<String, AutoGroupTagOrigin> origins;
  final List<String> warnings;

  int get serverCount => (config['outbounds'] as List).length + (config['endpoints'] as List).length;
}

/// Concatenates the leaf outbounds/endpoints of several profiles into one flat list.
/// Groups are dropped because the core rebuilds `select`/`lowest`/`balance` itself
/// (`hiddify-core/v2/config/builder.go`, `setOutbounds`).
class AutoGroupMerger {
  AutoGroupMerger._();

  static const String separator = ' · ';
  static const int prefixMaxLength = 12;
  static const String fallbackPrefix = 'Sub';
  static const Set<String> groupTypes = {'selector', 'urltest', 'balancer'};
  static const Set<String> reservedTags = {'direct', 'block', 'dns-out', 'dns', 'bypass'};
  static const Set<String> reservedTypes = {'direct', 'block', 'dns'};

  static String prefixFor(String profileName) {
    final collapsed = profileName.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (collapsed.isEmpty) return fallbackPrefix;
    if (collapsed.length <= prefixMaxLength) return collapsed;
    return collapsed.substring(0, prefixMaxLength).trimRight();
  }

  static AutoGroupMergeResult merge(List<AutoGroupSource> sources) {
    final outbounds = <Map<String, dynamic>>[];
    final endpoints = <Map<String, dynamic>>[];
    final origins = <String, AutoGroupTagOrigin>{};
    final warnings = <String>[];
    final seenCanonical = <String, String>{}; // canonical json -> merged tag
    final usedPrefixes = <String>{};

    for (final src in sources) {
      final prefix = _uniquePrefix(prefixFor(src.profileName), usedPrefixes);
      final rawOutbounds = _leafList(src.config['outbounds']);
      final rawEndpoints = _leafList(src.config['endpoints']);
      if (rawOutbounds.isEmpty && rawEndpoints.isEmpty) {
        warnings.add('"${src.profileName}" contains no servers and was skipped');
        continue;
      }

      // first pass: tag map for detour rewriting within this profile
      final tagMap = <String, String>{};
      for (final item in [...rawOutbounds, ...rawEndpoints]) {
        final tag = item['tag'] as String;
        tagMap[tag] = '$prefix$separator$tag';
      }

      void add(List<Map<String, dynamic>> raw, List<Map<String, dynamic>> target) {
        for (final item in raw) {
          final originalTag = item['tag'] as String;
          final merged = Map<String, dynamic>.from(item)..['tag'] = tagMap[originalTag];
          if (merged['detour'] is String && tagMap.containsKey(merged['detour'])) {
            merged['detour'] = tagMap[merged['detour']];
          }
          final canonical = _canonical(merged);
          final duplicateOf = seenCanonical[canonical];
          if (duplicateOf != null) {
            warnings.add('duplicate server "${merged['tag']}" skipped (same as "$duplicateOf")');
            continue;
          }
          seenCanonical[canonical] = merged['tag'] as String;
          origins[merged['tag'] as String] = AutoGroupTagOrigin(
            profileId: src.profileId,
            profileName: src.profileName,
            originalTag: originalTag,
          );
          target.add(merged);
        }
      }

      add(rawOutbounds, outbounds);
      add(rawEndpoints, endpoints);
    }

    return AutoGroupMergeResult(
      config: {'outbounds': outbounds, 'endpoints': endpoints},
      origins: origins,
      warnings: warnings,
    );
  }

  static String _uniquePrefix(String base, Set<String> used) {
    var candidate = base;
    var n = 2;
    while (used.contains(candidate)) {
      candidate = '$base $n';
      n++;
    }
    used.add(candidate);
    return candidate;
  }

  /// Leaf servers only: no groups, no infrastructure outbounds, and every item must carry a string tag.
  static List<Map<String, dynamic>> _leafList(Object? list) {
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .where((e) => e['tag'] is String && e['type'] is String)
        .where((e) => !groupTypes.contains(e['type']))
        .where((e) => !reservedTypes.contains(e['type']))
        .where((e) => !reservedTags.contains(e['tag']))
        .toList();
  }

  /// Stable JSON of the item without its tag, used to detect the same server offered twice.
  static String _canonical(Map<String, dynamic> item) {
    final copy = Map<String, dynamic>.from(item)..remove('tag');
    return jsonEncode(_sorted(copy));
  }

  static Object? _sorted(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((k) => k.toString()).toList()..sort();
      return {for (final k in keys) k: _sorted(value[k])};
    }
    if (value is List) return value.map(_sorted).toList();
    return value;
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `/c/src/flutter/bin/flutter test test/features/auto_group/data/auto_group_merger_test.dart`
Expected: 9 tests pass.

- [ ] **Step 5: Commit**

```bash
/c/src/flutter/bin/dart format lib test
git add lib/features/auto_group/data/auto_group_merger.dart test/features/auto_group
git commit -m "feat(auto-group): чистая склейка серверов нескольких подписок"
```

---

### Task 6: Auto group repository, failure type, preference and providers

**Files:**
- Create: `lib/features/auto_group/model/auto_group_failure.dart`
- Create: `lib/features/auto_group/data/auto_group_repository.dart`
- Create: `lib/features/auto_group/data/auto_group_data_providers.dart`
- Create: `lib/features/auto_group/notifier/auto_group_notifier.dart`
- Modify: `lib/core/preferences/general_preferences.dart:118`
- Test: `test/features/auto_group/data/auto_group_repository_test.dart`

**Interfaces:**
- Consumes: `AutoGroupMerger.merge`, `ProfileRepository.watchAutoGroupMembers/setIncludeInAuto`, `ProfilePathResolver.file(id)`, `HiddifyCoreService.validateConfigByPath(path, tempPath, debug)`.
- Produces:
```dart
sealed class AutoGroupFailure { String get message; }
class AutoGroupNoMembers extends AutoGroupFailure {}
class AutoGroupNoServers extends AutoGroupFailure { final List<String> warnings; }
class AutoGroupInvalidConfig extends AutoGroupFailure { final String detail; }
class AutoGroupUnexpected extends AutoGroupFailure { final Object error; }

class AutoGroupBuild { final String configPath; final int profileCount; final int serverCount; final List<String> warnings; final DateTime builtAt; }

abstract interface class AutoGroupRepository {
  static const configId = 'auto-group';           // configs/auto-group.json
  Stream<Either<ProfileFailure, List<ProfileEntity>>> watchMembers();
  TaskEither<ProfileFailure, Unit> setMembership(String id, bool value);
  TaskEither<AutoGroupFailure, AutoGroupBuild> buildConfig();
  AutoGroupBuild? get lastBuild;
}
Preferences.autoGroupEnabled  // PreferencesNotifier<bool>, key "auto_group_enabled", default false
autoGroupRepositoryProvider    // keepAlive, AutoGroupRepository
autoGroupMembersProvider       // keepAlive Stream<List<ProfileEntity>>
AutoGroupNotifier              // keepAlive; state AutoGroupBuild?; toggleMembership(id, value), setEnabled(bool), recordBuild(build)
```

- [ ] **Step 1: Write the failing repository test**

The test injects a fake `HiddifyCoreService`-like validator, so the repository takes a function `Future<Either<String, Unit>> Function(String path, String tempPath)` named `validate` instead of the whole service. `test/features/auto_group/data/auto_group_repository_test.dart`:
```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/features/auto_group/data/auto_group_repository.dart';
import 'package:hiddify/features/auto_group/model/auto_group_failure.dart';
import 'package:hiddify/features/profile/data/profile_path_resolver.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory workDir;
  late ProfilePathResolver resolver;

  ProfileEntity profile(String id, String name) =>
      ProfileEntity.remote(id: id, active: false, name: name, url: 'https://x/$id', lastUpdate: DateTime(2026), includeInAuto: true);

  void writeProfile(String id, List<Map<String, dynamic>> outbounds) {
    resolver.file(id).writeAsStringSync(jsonEncode({'outbounds': outbounds}));
  }

  Map<String, dynamic> vless(String tag, String host) =>
      {'type': 'vless', 'tag': tag, 'server': host, 'server_port': 443, 'uuid': '00000000-0000-0000-0000-000000000000'};

  setUp(() {
    workDir = Directory.systemTemp.createTempSync('recon_auto_group');
    resolver = ProfilePathResolver(workDir);
    resolver.directory.createSync(recursive: true);
  });

  tearDown(() => workDir.deleteSync(recursive: true));

  AutoGroupRepositoryImpl repo(List<ProfileEntity> members, {Future<Either<String, Unit>> Function(String, String)? validate}) =>
      AutoGroupRepositoryImpl(
        profilePathResolver: resolver,
        watchMembersSource: () => Stream.value(right(members)),
        setMembershipSource: (_, __) async {},
        validate: validate ?? (path, tempPath) async {
          // emulate the core: copy temp to final
          File(path).writeAsStringSync(File(tempPath).readAsStringSync());
          return right(unit);
        },
      );

  test('fails with noMembers when nothing is included', () async {
    final result = await repo([]).buildConfig().run();
    expect(result.getLeft().toNullable(), isA<AutoGroupNoMembers>());
  });

  test('merges member files, writes config and meta, records lastBuild', () async {
    writeProfile('a', [vless('NL', 'a.example.com')]);
    writeProfile('b', [vless('DE', 'b.example.com')]);
    final r = repo([profile('a', 'Alpha'), profile('b', 'Beta')]);

    final build = (await r.buildConfig().run()).getOrElse((l) => fail(l.message));
    expect(build.profileCount, 2);
    expect(build.serverCount, 2);
    expect(build.configPath, resolver.file(AutoGroupRepository.configId).path);
    expect(r.lastBuild, same(build));

    final written = jsonDecode(File(build.configPath).readAsStringSync()) as Map;
    expect((written['outbounds'] as List).length, 2);
    final meta = jsonDecode(File(p.join(resolver.directory.path, 'auto-group.meta.json')).readAsStringSync()) as Map;
    expect((meta['origins'] as Map).keys, containsAll(['Alpha · NL', 'Beta · DE']));
    expect(resolver.tempFile(AutoGroupRepository.configId).existsSync(), isFalse);
  });

  test('skips a member whose file is missing and warns', () async {
    writeProfile('a', [vless('NL', 'a.example.com')]);
    final r = repo([profile('a', 'Alpha'), profile('missing', 'Ghost')]);
    final build = (await r.buildConfig().run()).getOrElse((l) => fail(l.message));
    expect(build.profileCount, 1);
    expect(build.warnings.single, contains('Ghost'));
  });

  test('fails with noServers when every member is empty or broken', () async {
    resolver.file('a').writeAsStringSync('not json');
    final result = await repo([profile('a', 'Broken')]).buildConfig().run();
    final failure = result.getLeft().toNullable();
    expect(failure, isA<AutoGroupNoServers>());
    expect((failure! as AutoGroupNoServers).warnings.single, contains('Broken'));
  });

  test('propagates core validation errors', () async {
    writeProfile('a', [vless('NL', 'a.example.com')]);
    final result = await repo([profile('a', 'Alpha')], validate: (_, __) async => left('bad config')).buildConfig().run();
    final failure = result.getLeft().toNullable();
    expect(failure, isA<AutoGroupInvalidConfig>());
    expect((failure! as AutoGroupInvalidConfig).detail, 'bad config');
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `/c/src/flutter/bin/flutter test test/features/auto_group/data/auto_group_repository_test.dart`
Expected: compile error, files not found.

- [ ] **Step 3: Failure type**

`lib/features/auto_group/model/auto_group_failure.dart`:
```dart
sealed class AutoGroupFailure {
  const AutoGroupFailure();

  String get message;
}

class AutoGroupNoMembers extends AutoGroupFailure {
  const AutoGroupNoMembers();

  @override
  String get message => 'no subscriptions are included in the auto group';
}

class AutoGroupNoServers extends AutoGroupFailure {
  const AutoGroupNoServers(this.warnings);

  final List<String> warnings;

  @override
  String get message => 'included subscriptions contain no servers: ${warnings.join('; ')}';
}

class AutoGroupInvalidConfig extends AutoGroupFailure {
  const AutoGroupInvalidConfig(this.detail);

  final String detail;

  @override
  String get message => 'merged config rejected by core: $detail';
}

class AutoGroupUnexpected extends AutoGroupFailure {
  const AutoGroupUnexpected(this.error, [this.stackTrace]);

  final Object error;
  final StackTrace? stackTrace;

  @override
  String get message => 'unexpected error while building auto group: $error';
}
```

- [ ] **Step 4: Repository**

`lib/features/auto_group/data/auto_group_repository.dart`:
```dart
import 'dart:convert';
import 'dart:io';

import 'package:fpdart/fpdart.dart';
import 'package:hiddify/features/auto_group/data/auto_group_merger.dart';
import 'package:hiddify/features/auto_group/model/auto_group_failure.dart';
import 'package:hiddify/features/profile/data/profile_path_resolver.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:path/path.dart' as p;

class AutoGroupBuild {
  const AutoGroupBuild({
    required this.configPath,
    required this.profileCount,
    required this.serverCount,
    required this.warnings,
    required this.builtAt,
  });

  final String configPath;
  final int profileCount;
  final int serverCount;
  final List<String> warnings;
  final DateTime builtAt;
}

typedef WatchMembersSource = Stream<Either<ProfileFailure, List<ProfileEntity>>> Function();
typedef SetMembershipSource = Future<void> Function(String id, bool value);
typedef ConfigValidator = Future<Either<String, Unit>> Function(String path, String tempPath);

abstract interface class AutoGroupRepository {
  static const String configId = 'auto-group';
  static const String metaFileName = 'auto-group.meta.json';
  static const String displayName = 'Recon Auto';

  Stream<Either<ProfileFailure, List<ProfileEntity>>> watchMembers();
  TaskEither<ProfileFailure, Unit> setMembership(String id, bool value);
  TaskEither<AutoGroupFailure, AutoGroupBuild> buildConfig();
  AutoGroupBuild? get lastBuild;
}

class AutoGroupRepositoryImpl with InfraLogger implements AutoGroupRepository {
  AutoGroupRepositoryImpl({
    required ProfilePathResolver profilePathResolver,
    required WatchMembersSource watchMembersSource,
    required SetMembershipSource setMembershipSource,
    required ConfigValidator validate,
  }) : _resolver = profilePathResolver,
       _watchMembers = watchMembersSource,
       _setMembership = setMembershipSource,
       _validate = validate;

  final ProfilePathResolver _resolver;
  final WatchMembersSource _watchMembers;
  final SetMembershipSource _setMembership;
  final ConfigValidator _validate;

  AutoGroupBuild? _lastBuild;

  @override
  AutoGroupBuild? get lastBuild => _lastBuild;

  @override
  Stream<Either<ProfileFailure, List<ProfileEntity>>> watchMembers() => _watchMembers();

  @override
  TaskEither<ProfileFailure, Unit> setMembership(String id, bool value) => TaskEither.tryCatch(() async {
    await _setMembership(id, value);
    return unit;
  }, ProfileUnexpectedFailure.new);

  @override
  TaskEither<AutoGroupFailure, AutoGroupBuild> buildConfig() => TaskEither(() async {
    try {
      final members = (await _watchMembers().first).getOrElse((l) => throw l);
      if (members.isEmpty) return left(const AutoGroupNoMembers());

      final sources = <AutoGroupSource>[];
      final warnings = <String>[];
      for (final member in members) {
        final file = _resolver.file(member.id);
        if (!file.existsSync()) {
          warnings.add('"${member.name}" has no downloaded config and was skipped');
          continue;
        }
        try {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is! Map) throw const FormatException('config root is not an object');
          sources.add(AutoGroupSource(profileId: member.id, profileName: member.name, config: decoded.cast<String, dynamic>()));
        } catch (e) {
          warnings.add('"${member.name}" config could not be read ($e) and was skipped');
        }
      }

      final merged = AutoGroupMerger.merge(sources);
      warnings.addAll(merged.warnings);
      if (merged.serverCount == 0) return left(AutoGroupNoServers(warnings));

      final target = _resolver.file(AutoGroupRepository.configId);
      final temp = _resolver.tempFile(AutoGroupRepository.configId);
      await temp.writeAsString(jsonEncode(merged.config));
      try {
        final validation = await _validate(target.path, temp.path);
        if (validation.isLeft()) {
          return left(AutoGroupInvalidConfig(validation.getLeft().toNullable() ?? 'unknown'));
        }
      } finally {
        if (temp.existsSync()) temp.deleteSync();
      }

      final metaFile = File(p.join(_resolver.directory.path, AutoGroupRepository.metaFileName));
      await metaFile.writeAsString(
        jsonEncode({
          'builtAt': DateTime.now().toIso8601String(),
          'origins': merged.origins.map((tag, origin) => MapEntry(tag, origin.toJson())),
          'warnings': warnings,
        }),
      );

      final build = AutoGroupBuild(
        configPath: target.path,
        profileCount: sources.length,
        serverCount: merged.serverCount,
        warnings: warnings,
        builtAt: DateTime.now(),
      );
      _lastBuild = build;
      loggy.info('auto group built: ${build.profileCount} profiles, ${build.serverCount} servers, ${warnings.length} warnings');
      return right(build);
    } catch (e, st) {
      loggy.error('auto group build failed', e, st);
      return left(AutoGroupUnexpected(e, st));
    }
  });
}
```

- [ ] **Step 5: Run the repository test**

Run: `/c/src/flutter/bin/flutter test test/features/auto_group/data/auto_group_repository_test.dart`
Expected: 5 tests pass.

- [ ] **Step 6: Preference, providers and notifier**

In `lib/core/preferences/general_preferences.dart` add inside `Preferences`:
```dart
  static final autoGroupEnabled = PreferencesNotifier.create<bool, bool>("auto_group_enabled", false);
```

`lib/features/auto_group/data/auto_group_data_providers.dart`:
```dart
import 'package:hiddify/features/auto_group/data/auto_group_repository.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'auto_group_data_providers.g.dart';

@Riverpod(keepAlive: true)
AutoGroupRepository autoGroupRepository(Ref ref) {
  final profiles = ref.watch(profileRepositoryProvider).requireValue;
  final singbox = ref.watch(hiddifyCoreServiceProvider);
  return AutoGroupRepositoryImpl(
    profilePathResolver: ref.watch(profilePathResolverProvider),
    watchMembersSource: profiles.watchAutoGroupMembers,
    setMembershipSource: (id, value) => profiles.setIncludeInAuto(id, value).getOrElse((l) => throw l).run(),
    validate: (path, tempPath) => singbox.validateConfigByPath(path, tempPath, false).run(),
  );
}
```
`profileRepositoryProvider` is a `FutureProvider`; `requireValue` matches how `ProfilesNotifier._profilesRepo` reads it. Callers of `autoGroupRepositoryProvider` must only run after the app bootstrap has awaited the profile repository (upstream does this in `lib/bootstrap.dart`; verify the exact call with `grep -n profileRepositoryProvider lib/bootstrap.dart`).

`lib/features/auto_group/notifier/auto_group_notifier.dart`:
```dart
import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/auto_group/data/auto_group_data_providers.dart';
import 'package:hiddify/features/auto_group/data/auto_group_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'auto_group_notifier.g.dart';

@Riverpod(keepAlive: true)
Stream<List<ProfileEntity>> autoGroupMembers(Ref ref) {
  return ref.watch(autoGroupRepositoryProvider).watchMembers().map((event) => event.getOrElse((l) => throw l));
}

/// Holds the result of the latest merge so the UI can show counts and warnings.
@Riverpod(keepAlive: true)
class AutoGroupNotifier extends _$AutoGroupNotifier with AppLogger {
  @override
  AutoGroupBuild? build() => ref.read(autoGroupRepositoryProvider).lastBuild;

  Future<void> toggleMembership(String id, bool value) async {
    loggy.debug('auto group membership [$id] -> $value');
    await ref.read(hapticServiceProvider.notifier).lightImpact();
    await ref.read(autoGroupRepositoryProvider).setMembership(id, value).getOrElse((err) {
      loggy.warning('failed to change auto group membership', err);
      throw err;
    }).run();
  }

  Future<void> setEnabled(bool value) async {
    await ref.read(hapticServiceProvider.notifier).lightImpact();
    await ref.read(Preferences.autoGroupEnabled.notifier).update(value);
  }

  void recordBuild(AutoGroupBuild build) => state = build;
}
```

- [ ] **Step 7: Codegen, analyze, tests**

```bash
/c/src/flutter/bin/dart run build_runner build --delete-conflicting-outputs
/c/src/flutter/bin/flutter analyze lib/features/auto_group lib/core/preferences
/c/src/flutter/bin/flutter test
```
Expected: clean analysis of the new files, all tests pass.

- [ ] **Step 8: Commit**

```bash
/c/src/flutter/bin/dart format lib test
git add lib/features/auto_group lib/core/preferences/general_preferences.dart test/features/auto_group
git commit -m "feat(auto-group): репозиторий сборки объединённого конфига и провайдеры"
```

---

### Task 7: Connect through the auto group

**Files:**
- Modify: `lib/features/connection/data/connection_repository.dart:18-26,80-97,99-136`
- Modify: `lib/features/connection/notifier/connection_notifier.dart:49-55,96-112,138-159`
- Modify: `lib/features/connection/data/connection_data_providers.dart`

**Interfaces:**
- Consumes: `AutoGroupRepository.buildConfig()`, `AutoGroupRepository.displayName`, `Preferences.autoGroupEnabled`, `autoGroupMembersProvider`, `AutoGroupNotifier.recordBuild`.
- Produces: `ConnectionRepository.connectAutoGroup(bool disableMemoryLimit)` and `reconnectAutoGroup(bool disableMemoryLimit)`, both `TaskEither<ConnectionFailure, Unit>`.

- [ ] **Step 1: Repository methods**

In `lib/features/connection/data/connection_repository.dart` add the imports
```dart
import 'package:hiddify/features/auto_group/data/auto_group_repository.dart';
import 'package:hiddify/features/auto_group/model/auto_group_failure.dart';
```
extend the interface:
```dart
  TaskEither<ConnectionFailure, Unit> connectAutoGroup(bool disableMemoryLimit);
  TaskEither<ConnectionFailure, Unit> reconnectAutoGroup(bool disableMemoryLimit);
```
add a constructor dependency `required this.autoGroupRepository,` (field `final AutoGroupRepository autoGroupRepository;`), and implement:
```dart
  @override
  TaskEither<ConnectionFailure, Unit> connectAutoGroup(bool disableMemoryLimit) => setup().flatMap(
    (_) => applyConfigOption(null).flatMap(
      (_) => _buildAutoGroup().flatMap(
        (build) => singbox.start(build.configPath, AutoGroupRepository.displayName, disableMemoryLimit),
      ),
    ),
  );

  @override
  TaskEither<ConnectionFailure, Unit> reconnectAutoGroup(bool disableMemoryLimit) => applyConfigOption(null).flatMap(
    (_) => _buildAutoGroup().flatMap(
      (build) => singbox
          .restart(build.configPath, AutoGroupRepository.displayName, disableMemoryLimit)
          .mapLeft(UnexpectedConnectionFailure.new),
    ),
  );

  TaskEither<ConnectionFailure, AutoGroupBuild> _buildAutoGroup() =>
      autoGroupRepository.buildConfig().mapLeft(
        (failure) => switch (failure) {
          AutoGroupInvalidConfig(:final detail) => ConnectionFailure.invalidConfig(detail),
          _ => ConnectionFailure.unexpected(failure.message),
        },
      );
```
Change `applyConfigOption` to take the override string instead of the entity so the auto group can pass `null`:
```dart
  @visibleForTesting
  TaskEither<ConnectionFailure, Unit> applyConfigOption(String? profileOverride) =>
      TaskEither.fromEither(configOptionRepository.fullOptionsOverrided(profileOverride))
```
and update the two existing callers: `applyConfigOption(activeProfile.profileOverride())` in `connect` and `reconnect`. Everything else inside `applyConfigOption` stays as is.

In `lib/features/connection/data/connection_data_providers.dart` add
`autoGroupRepository: ref.watch(autoGroupRepositoryProvider),` with the import `package:hiddify/features/auto_group/data/auto_group_data_providers.dart`.

- [ ] **Step 2: Notifier mode switch**

In `lib/features/connection/notifier/connection_notifier.dart` add imports:
```dart
import 'package:hiddify/features/auto_group/data/auto_group_data_providers.dart';
import 'package:hiddify/features/auto_group/notifier/auto_group_notifier.dart';
```
Replace the `activeProfileProvider` listener block (lines 49-55) with:
```dart
    ref.listen(activeProfileProvider.select((value) => value.asData?.value), (previous, next) async {
      if (previous == null) return;
      if (ref.read(Preferences.autoGroupEnabled)) return; // auto mode ignores the active profile
      final shouldReconnect = next == null || previous.id != next.id;
      if (shouldReconnect) {
        await reconnect(next);
      }
    });

    ref.listen(Preferences.autoGroupEnabled, (previous, next) async {
      if (previous == null || previous == next) return;
      await _reconnectForCurrentMode();
    });

    // membership set or a member's content changed -> rebuild the merged config while connected in auto mode
    ref.listen(
      autoGroupMembersProvider.select(
        (value) => value.asData?.value.map((p) => '${p.id}:${p.lastUpdate.millisecondsSinceEpoch}').join(','),
      ),
      (previous, next) async {
        if (previous == null || previous == next) return;
        if (!ref.read(Preferences.autoGroupEnabled)) return;
        await _reconnectForCurrentMode();
      },
    );
```
Add the helper and the auto-mode branches:
```dart
  Future<void> _reconnectForCurrentMode() async {
    if (state case AsyncData(:final value) when value == const Connected()) {
      if (ref.read(Preferences.autoGroupEnabled)) {
        loggy.info("auto group changed, reconnecting");
        await _connectionRepo.reconnectAutoGroup(ref.read(Preferences.disableMemoryLimit)).mapLeft(_onReconnectError).run();
        _publishAutoGroupBuild();
      } else {
        await reconnect(await ref.read(activeProfileProvider.future));
      }
    }
  }

  Future<void> _onReconnectError(ConnectionFailure err) async {
    loggy.warning("error reconnecting", err);
    state = AsyncError(err, StackTrace.current);
    await ref.read(dialogNotifierProvider.notifier).showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
  }

  void _publishAutoGroupBuild() {
    final build = ref.read(autoGroupRepositoryProvider).lastBuild;
    if (build != null) ref.read(autoGroupNotifierProvider.notifier).recordBuild(build);
  }
```
In `_connectThrottled` add the auto branch at the top:
```dart
  Future<void> _connectThrottled() async {
    if (ref.read(Preferences.autoGroupEnabled)) {
      await _connectionRepo.connectAutoGroup(ref.read(Preferences.disableMemoryLimit)).mapLeft(_onConnectError).run();
      _publishAutoGroupBuild();
      return;
    }
    final activeProfile = await ref.read(activeProfileProvider.future);
    if (activeProfile == null) {
      loggy.info("no active profile, not connecting");
      return;
    }
    await _connectionRepo.connect(activeProfile, ref.read(Preferences.disableMemoryLimit)).mapLeft(_onConnectError).run();
  }

  Future<void> _onConnectError(ConnectionFailure err) async {
    loggy.warning("error connecting", err);
    await ref.read(dialogNotifierProvider.notifier).showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
    if (err.toString().contains("panic")) {
      await Sentry.captureException(Exception(err.toString()));
    }
    await ref.read(Preferences.startedByUser.notifier).update(false);
    state = AsyncError(err, StackTrace.current);
  }
```
(The body of `_onConnectError` is the former inline `mapLeft` closure moved into a method; behaviour unchanged for manual mode.)

- [ ] **Step 3: Codegen, analyze, tests, build**

```bash
/c/src/flutter/bin/dart run build_runner build --delete-conflicting-outputs
/c/src/flutter/bin/flutter analyze lib/features/connection
/c/src/flutter/bin/flutter test
/c/src/flutter/bin/flutter build apk --debug --target-platform android-arm64
```
Expected: no analyzer errors, tests pass, APK builds.

- [ ] **Step 4: Commit**

```bash
/c/src/flutter/bin/dart format lib test
git add lib/features/connection
git commit -m "feat(connection): подключение через объединённую группу подписок"
```

---

### Task 8: UI — membership toggle, marker, home card, strings

**Files:**
- Modify: `assets/translations/en.i18n.json`, `assets/translations/ru.i18n.json`
- Modify: `lib/features/profile/widget/profile_tile.dart` (`ProfileActionsMenu` items; non-main name row)
- Create: `lib/features/auto_group/widget/auto_group_card.dart`
- Modify: `lib/features/home/widget/home_page.dart:103-111`

**Interfaces:**
- Consumes: `autoGroupMembersProvider`, `autoGroupNotifierProvider` (`AutoGroupBuild?` state, `toggleMembership`, `setEnabled`), `Preferences.autoGroupEnabled`, `ProfileEntity.includeInAuto`.
- Produces: translation keys `pages.home.autoGroup.*`, `pages.profiles.autoGroup.*`.

- [ ] **Step 1: Add strings**

In `assets/translations/en.i18n.json` under `pages.home` add:
```json
"autoGroup": {
  "title": "Auto group",
  "subscriptions": "Subscriptions: ${count}",
  "servers": "Servers: ${count}",
  "enabled": "Auto-switch between all included subscriptions",
  "disabled": "Off. Connection uses the active profile",
  "warnings": "Warnings: ${count}",
  "semanticSwitch": "Auto group switch"
}
```
and under `pages.profiles`:
```json
"autoGroup": {
  "include": "Include in auto group",
  "exclude": "Remove from auto group",
  "member": "In auto group"
}
```
Under `common` change `"appTitle": "Hiddify"` to `"appTitle": "Recon"`.
In `ru.i18n.json` the same keys with:
`pages.home.autoGroup`: title "Автовыбор", subscriptions "Подписок: ${count}", servers "Серверов: ${count}", enabled "Автопереключение между всеми включёнными подписками", disabled "Выключен. Подключение идёт через активный профиль", warnings "Предупреждений: ${count}", semanticSwitch "Переключатель автовыбора";
`pages.profiles.autoGroup`: include "Добавить в автовыбор", exclude "Убрать из автовыбора", member "В автовыборе"; `common.appTitle` "Recon".
Then run `/c/src/flutter/bin/dart run slang` and confirm `lib/gen/translations.g.dart` contains `autoGroup`.

- [ ] **Step 2: Menu item and marker in the profile tile**

In `lib/features/profile/widget/profile_tile.dart` add the import
`import 'package:hiddify/features/auto_group/notifier/auto_group_notifier.dart';`
In `ProfileActionsMenu.build`, insert before the delete item:
```dart
      AdaptiveMenuItem(
        leadingIcon: Icon(profile.includeInAuto ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded),
        title: profile.includeInAuto ? t.pages.profiles.autoGroup.exclude : t.pages.profiles.autoGroup.include,
        onTap: () async =>
            await ref.read(autoGroupNotifierProvider.notifier).toggleMembership(profile.id, !profile.includeInAuto),
      ),
```
In `ProfileTile.build`, replace the non-main `Text(profile.name, ...)` (the `else` branch) with a row that adds a small marker when the profile is a member:
```dart
                          else
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    profile.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleMedium?.copyWith(
                                      fontFamily: PlatformUtils.isWindows ? FontFamily.emoji : null,
                                    ),
                                    semanticsLabel: profile.active
                                        ? t.pages.profiles.activeProfileName(name: profile.name)
                                        : t.pages.profiles.nonActiveProfileName(name: profile.name),
                                  ),
                                ),
                                if (profile.includeInAuto) ...[
                                  const Gap(6),
                                  Tooltip(
                                    message: t.pages.profiles.autoGroup.member,
                                    child: Icon(Icons.alt_route_rounded, size: 18, color: theme.colorScheme.primary),
                                  ),
                                ],
                              ],
                            ),
```

- [ ] **Step 3: Home card**

`lib/features/auto_group/widget/auto_group_card.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/features/auto_group/notifier/auto_group_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Home-screen card mirroring [ProfileTile]'s shape: same radius, margin and surface colour.
class AutoGroupCard extends HookConsumerWidget {
  const AutoGroupCard({super.key, this.margin = const EdgeInsets.symmetric(horizontal: 16, vertical: 8)});

  final EdgeInsets margin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final enabled = ref.watch(Preferences.autoGroupEnabled);
    final members = ref.watch(autoGroupMembersProvider).valueOrNull ?? const [];
    final lastBuild = ref.watch(autoGroupNotifierProvider);

    return Card(
      margin: margin,
      elevation: enabled ? 0 : 1,
      color: theme.colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        side: enabled ? BorderSide(color: theme.colorScheme.outline) : BorderSide.none,
        borderRadius: ProfileTileConst.cardBorderRadius,
      ),
      child: InkWell(
        borderRadius: ProfileTileConst.cardBorderRadius,
        onTap: () => ref.read(bottomSheetsNotifierProvider.notifier).showProfilesOverview(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.alt_route_rounded, color: theme.colorScheme.primary),
              const Gap(12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.pages.home.autoGroup.title, style: theme.textTheme.titleMedium),
                    const Gap(2),
                    Text(
                      enabled ? t.pages.home.autoGroup.enabled : t.pages.home.autoGroup.disabled,
                      style: theme.textTheme.bodySmall,
                    ),
                    const Gap(2),
                    Text(
                      [
                        t.pages.home.autoGroup.subscriptions(count: members.length),
                        if (lastBuild != null) t.pages.home.autoGroup.servers(count: lastBuild.serverCount),
                        if (lastBuild != null && lastBuild.warnings.isNotEmpty)
                          t.pages.home.autoGroup.warnings(count: lastBuild.warnings.length),
                      ].join('  ·  '),
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    if (lastBuild != null && lastBuild.warnings.isNotEmpty) ...[
                      const Gap(4),
                      Text(
                        lastBuild.warnings.first,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                      ),
                    ],
                  ],
                ),
              ),
              Semantics(
                label: t.pages.home.autoGroup.semanticSwitch,
                child: Switch.adaptive(
                  value: enabled,
                  onChanged: (value) => ref.read(autoGroupNotifierProvider.notifier).setEnabled(value),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
```
`ProfileTileConst` lives in `lib/core/model/constants.dart` (imported by `profile_tile.dart` the same way).

- [ ] **Step 4: Show the card on the home page**

In `lib/features/home/widget/home_page.dart` add imports
```dart
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/auto_group/notifier/auto_group_notifier.dart';
import 'package:hiddify/features/auto_group/widget/auto_group_card.dart';
```
read the state at the top of `build`:
```dart
    final autoGroupEnabled = ref.watch(Preferences.autoGroupEnabled);
    final hasAutoMembers = (ref.watch(autoGroupMembersProvider).valueOrNull ?? const []).isNotEmpty;
```
and replace the `MultiSliver` children head (lines 103-111) with:
```dart
                        if (hasAutoMembers) const SliverToBoxAdapter(child: AutoGroupCard()),
                        if (!(hasAutoMembers && autoGroupEnabled))
                          switch (activeProfile) {
                            AsyncData(value: final profile?) => ProfileTile(
                              profile: profile,
                              isMain: true,
                              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              color: Theme.of(context).colorScheme.surfaceContainer,
                            ),
                            _ => const Text(""),
                          },
```

- [ ] **Step 5: App label**

In `android/app/src/main/AndroidManifest.xml` line 31 change `android:label="Hiddify"` to `android:label="Recon"`.

- [ ] **Step 6: Codegen, analyze, tests, build, install**

```bash
/c/src/flutter/bin/dart run slang
/c/src/flutter/bin/dart run build_runner build --delete-conflicting-outputs
/c/src/flutter/bin/flutter analyze lib/features/auto_group lib/features/home lib/features/profile/widget
/c/src/flutter/bin/flutter test
/c/src/flutter/bin/flutter build apk --debug --target-platform android-arm64
```
Expected: clean, tests pass, APK builds. Manual smoke on a connected device (owner):
```bash
"$LOCALAPPDATA/Android/Sdk/platform-tools/adb" install -r build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk
```
The app is labelled Recon, profile menus show "Include in auto group", the home card appears once a profile is included.

- [ ] **Step 7: Commit**

```bash
/c/src/flutter/bin/dart format lib test
git add assets/translations lib/gen lib/features/profile/widget/profile_tile.dart lib/features/auto_group/widget lib/features/home/widget/home_page.dart android/app/src/main/AndroidManifest.xml
git commit -m "feat(ui): карточка автовыбора, отметка подписок, название Recon"
```

---

### Task 9: CI workflow building the APK on GitHub Actions

**Files:**
- Create: `.github/workflows/recon-android.yml`

**Interfaces:**
- Produces: an `apk` artifact on every push to `recon/main` and on manual dispatch.

- [ ] **Step 1: Write the workflow**

```yaml
name: Recon Android

on:
  push:
    branches: [recon/main]
  workflow_dispatch:

concurrency:
  group: recon-android-${{ github.ref }}
  cancel-in-progress: true

jobs:
  apk:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: "17"

      - uses: subosito/flutter-action@v2
        with:
          flutter-version: "3.38.5"
          channel: stable
          cache: true

      - name: Download prebuilt core
        run: |
          CORE_VERSION=$(sed -n 's/^core.version=//p' dependencies.properties)
          mkdir -p android/app/libs
          curl -fL "https://github.com/hiddify/hiddify-core/releases/download/v${CORE_VERSION}/hiddify-lib-android.tar.gz" | tar xz -C android/app/libs/
          ls -la android/app/libs

      - name: Generate code
        run: |
          flutter pub get
          dart run build_runner build --delete-conflicting-outputs
          dart run slang

      - name: Test
        run: flutter test

      - name: Build APK
        run: flutter build apk --release --split-per-abi

      - uses: actions/upload-artifact@v4
        with:
          name: recon-apk
          path: build/app/outputs/flutter-apk/*.apk
          if-no-files-found: error
```
Release builds without a keystore fall back to the debug signing config (`android/app/build.gradle:104-108`), which is enough for side-loading.

- [ ] **Step 2: Push and watch the run**

```bash
git add .github/workflows/recon-android.yml
git commit -m "chore(ci): сборка APK Recon в GitHub Actions"
git push recon recon/main
gh run watch --repo bambolumba-y/Recon --exit-status
```
Expected: run green; `gh run download --repo bambolumba-y/Recon -n recon-apk -D /tmp/recon-apk` yields `app-arm64-v8a-release.apk`. If the runner fails on a step that passes locally, fix the workflow in a follow-up commit; do not skip the test step.

---

### Task 10: Device acceptance for Stage 1 (owner + main session)

**Files:**
- Create: `docs/2026-09-XX_stage1_device_test.md` in the fork (date of execution)

**Interfaces:**
- Consumes: the CI or local APK from Tasks 8-9.

- [ ] **Step 1: Prepare provider slots**

Owner frees one device slot in the Alpha bot (`@provider-a-bot`) and one in the Beta bot (`@provider-b-support` support / the bot's device list) so the new HWID is accepted.

- [ ] **Step 2: Install and add subscriptions**

```bash
"$LOCALAPPDATA/Android/Sdk/platform-tools/adb" install -r build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk
"$LOCALAPPDATA/Android/Sdk/platform-tools/adb" logcat -c
```
In the app: add both subscription URLs. Expected: each profile shows real server names on the Proxies page, not "App not supported". If a stub appears, capture headers by re-adding after `adb logcat | grep -i hwid` and check the device slot in the bot.

- [ ] **Step 3: Enable the auto group**

Mark both profiles via the menu, enable the switch on the home card, connect. Expected:
- notification/name shows `Recon Auto`;
- Proxies page lists both pools with `Alpha · ...` / `🛡 @provider-b-bot · ...` style names under the `select` group with `lowest` chosen by default;
- browser traffic works; home card shows `Subscriptions: 2 · Servers: N`.

- [ ] **Step 4: Update and delete paths**

Pull-to-refresh one subscription while connected: the connection restarts on its own (log line `auto group changed, reconnecting`) and stays usable. Remove one profile from the group: same. Disable the switch: the app reconnects through the active profile.

- [ ] **Step 5: Collect evidence and close the stage**

```bash
"$LOCALAPPDATA/Android/Sdk/platform-tools/adb" logcat -d | grep -iE 'auto group|Recon Auto|balancer|lowest' > docs/stage1_logcat_excerpt.txt
```
Write `docs/2026-09-XX_stage1_device_test.md` with: build id, both providers' server counts, observed switch behaviour for 30 minutes of normal use, any warning shown on the card. Commit with `docs(stage1): результаты проверки на устройстве`. Stage 2 planning starts from this file.

---

## Self-review

**Spec coverage (Stage 1 sections):**
- 4.1 storage: Task 3 (column, DAO), Task 4 (entity), Task 6 (`autoGroupEnabled`).
- 4.2 merge rules 1-6: Task 5 (leaf-only, prefixes, detour rewrite, dedupe, warnings, zero servers) and Task 6 (missing/broken file skipped, meta sidecar, validation through core, re-merge on update via Task 7 listener).
- 4.3 UI: Task 8 (menu toggle, marker, home card with switch, counts, warnings; proxies screen unchanged). "Current server with its subscription name" is satisfied by the prefixed tag shown by the existing active proxy widgets; the last switch reason is Stage 2 (section 5.6) and is not promised here.
- 4.4 acceptance: Task 1 (Windows build on prebuilt core), Task 10 (two real subscriptions), Task 5 tests.
- Section 6 error table: rows 1-4 and 7 covered by Tasks 6-8; rows 5-6 are Stage 2.
- Section 8 HWID requirement: Task 2.
- License conditions 1-2: Tasks 1 and 9.

**Placeholder scan:** none of "TBD/TODO/implement later"; the only unspecified value is the date in Task 10's file name, which is the execution date.

**Type consistency:** `AutoGroupRepository.configId`, `displayName`, `metaFileName` used identically in Tasks 6-7; `AutoGroupBuild` fields (`configPath`, `profileCount`, `serverCount`, `warnings`, `builtAt`) match between Task 6 code, Task 6 test and Task 8 card; `ProfileRepository.setIncludeInAuto/watchAutoGroupMembers` names match Task 4 and Task 6 wiring; `applyConfigOption(String?)` signature change in Task 7 updates both existing callers.
