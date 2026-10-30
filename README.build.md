# Building this fork

Run from PowerShell 7.2 or newer, in the repository directory:

```powershell
.\build.ps1
```

The default builds a **Debug APK**, runs the app's unit tests, verifies the APK's
bundled license texts and copies the APK, SHA256 checksum and build information to
`_artifacts/`. Nothing is installed or deployed. Debug builds use
`org.jellyfin.androidtv.debug`, separate from the release app.

## Prerequisites

- PowerShell 7.2+ (`pwsh`).
- Android SDK with the compile API declared in `gradle/libs.versions.toml`
  (currently API 37, including platforms named `android-37.0`) and build tools.
  Install these through Android Studio's SDK Manager.
- Internet access for the first Gradle, dependency, JDK and license downloads.

The script reads the SDK from `local.properties`, `ANDROID_HOME`,
`ANDROID_SDK_ROOT`, or the normal Windows Android Studio SDK location. A supplied
`-AndroidSdk` must agree with an existing `sdk.dir`; the script never rewrites
`local.properties`.

The required JDK version comes from the same version catalog (currently JDK 21).
The script checks `-JavaHome`, `JAVA_HOME`, its own cache, Java on PATH and common
Windows JDK installation locations. If necessary, it downloads a portable Temurin
JDK from Adoptium on Windows, checks the official SHA256 before extraction and
keeps it in `.build/toolchains/`. No system-wide installation is needed.
On other operating systems, install the matching JDK and select it with
`JAVA_HOME` or `-JavaHome`.

The selected JDK is provided to Gradle as both the launcher and a compiler
toolchain. An existing `gradle/gradle-daemon-jvm.properties` is preserved; it may
choose a different compatible daemon JVM. On a fresh checkout there is no local
daemon override. The script restores the calling process's environment and
working directory when it finishes.

## Options

```powershell
.\build.ps1 -Help
.\build.ps1 -SkipTests
.\build.ps1 -Version 0.20.0-alien21.1
.\build.ps1 -JavaHome C:\Java\jdk-21 -AndroidSdk C:\Android\Sdk
```

`-Version` overrides `JELLYFIN_VERSION`; without it, Gradle keeps its normal
version selection. Use `MAJOR.MINOR.PATCH`, optionally followed by `-LABEL.NUMBER`
and optionally prefixed by `v`, matching Gradle's numeric version-code rules.
`-SkipTests` skips the unit-test task and records that fact in
the build information instead of reporting old test results as a new run.
Release signing and device installation remain separate Gradle/Android tasks.

## Cache, licenses and outputs

Everything managed by this script stays inside the checkout:

- `.build/toolchains/`: downloaded JDKs and checksum provenance.
- `.build/licenses/`: cached, complete license texts and plugin configuration.
- `.build/logs/`: timestamped Gradle build logs.
- `_artifacts/`: current metadata-selected APK, `.apk.sha256` and `.apk.build.json`.
- `app/build/reports/tests/testDebugUnitTest/`: Gradle's unit-test report.

Gradle also uses its normal user-level dependency/distribution cache.

`.build/` and `_artifacts/` are ignored by Git. Neither previous APKs nor files
outside these output locations are deleted. The original Gradle APK remains in
`app/build/outputs/apk/debug/`.

The tracked helpers in `build-support/` obtain license texts using bounded HTTPS
requests and official SPDX/GNU sources, then feed them through AboutLibraries'
supported `collect.configPath` setting. This avoids its unbounded license-text
download during the build. No dependency on another checkout, old APK or files
in an external artifacts directory exists. Cached texts are checked before
reuse, and the final APK is rejected if a referenced license is missing or its
text is incomplete. Gradle offline mode is not enabled and new dependencies
continue through the normal dependency resolution process.

Failures stop packaging and return a nonzero exit code. A checkout lock prevents
two `build.ps1` invocations from overwriting each other's outputs.
