# Building this fork

Run from PowerShell 7.2 or newer, in the repository directory:

```powershell
.\build.ps1
```

The default builds an optimized, **signed Release APK** with application ID
`org.jellyfin.androidtv` and runs the app's Release unit tests. Before copying the
APK, the script verifies its actual signature, application ID, non-debuggable
status and bundled license texts. It then copies the APK, SHA256 checksum and
build information to `_artifacts/`. Nothing is installed or deployed.

Use `-Debug` explicitly for a Debug APK and Debug unit tests. Debug builds use
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
.\build.ps1 -Debug
.\build.ps1 -SkipTests
.\build.ps1 -Version 0.20.0-alien21.1
.\build.ps1 -JavaHome C:\Java\jdk-21 -AndroidSdk C:\Android\Sdk
```

`-Version` overrides `JELLYFIN_VERSION`; without it, Gradle keeps its normal
version selection. Use `MAJOR.MINOR.PATCH`, optionally followed by `-LABEL.NUMBER`
and optionally prefixed by `v`, matching Gradle's numeric version-code rules.
`-SkipTests` skips the selected configuration's unit-test task and records that
fact in the build information instead of reporting old test results as a new
run. APK signature, application ID and license verification still run.

For Release unit tests, the wrapper enables
`android.onlyEnableUnitTestForTheTestedBuildType=false` for that invocation.
[AGP 9 otherwise creates unit tests only for the default tested build type](https://developer.android.com/build/releases/agp-9-0-0-release-notes).
The project configuration is not rewritten.
## Release signing

For an existing signing identity, configure all four standard Gradle properties
or their corresponding environment variables:

| Gradle property | Environment variable |
| --- | --- |
| `keystore.file` | `KEYSTORE_FILE` |
| `keystore.password` | `KEYSTORE_PASSWORD` |
| `signing.key.alias` | `SIGNING_KEY_ALIAS` |
| `signing.key.password` | `SIGNING_KEY_PASSWORD` |

Each Gradle property takes precedence over its environment variable. Prefer
user-level `~/.gradle/gradle.properties` for signing secrets, rather than the
tracked project file, and use an absolute path for the keystore. Do not pass
passwords on the command line or commit them to Git.

A complete external configuration is reused. A partial or invalid external
configuration stops the build; the script never falls back to another signing
identity when an existing configuration is incomplete or unusable.

When no external signing configuration is present and `.signing/` is empty, the
first Release build automatically creates a persistent PKCS12 signing key and
secure random credentials. The private files are:

- `.signing/fork-release.p12`: the private signing key and certificate.
- `.signing/credentials.json`: the generated signing credentials.
- `.signing/identity.json`: signing identity metadata and public certificate
  fingerprint.

The helper applies private filesystem permissions. Later Release builds reuse
this identity and verify its certificate fingerprint. Partial or corrupt signing
state stops the build instead of generating a replacement key. Signing state is
revalidated on every invocation; the wrapper disables Gradle's configuration
cache for this workflow.

**Back up the entire `.signing/` directory securely.** It is persistent signing
state, separate from the disposable `.build/` cache, and is ignored by Git. To
continue building updates in a fresh checkout or on another computer, restore
the complete directory before the first Release build. Keep its contents private;
passwords and private keys are never included in logs, APK build information or
Git.

Android updates require the same signing certificate. A fork APK signed with a
different key cannot replace an installed official Jellyfin release or a fork
release signed with another key. Reuse the original fork signing identity for
subsequent updates and choose a version code that does not downgrade the
installed app.

The final APK's public signing certificate SHA256 is recorded in its
`.apk.build.json`; this fingerprint identifies the signing certificate without
exposing the private key or credentials.

## Cache, licenses and outputs

Everything managed by this script stays inside the checkout:

- `.build/toolchains/`: downloaded JDKs and checksum provenance.
- `.build/licenses/`: cached, complete license texts and plugin configuration.
- `.build/logs/`: timestamped Gradle build logs.
- `.signing/`: persistent, private fork signing identity; retain it and keep a secure backup.
- `_artifacts/`: current metadata-selected APK, `.apk.sha256` and `.apk.build.json`.
- `app/build/reports/tests/testReleaseUnitTest/`: default unit-test report.
- `app/build/reports/tests/testDebugUnitTest/`: unit-test report with `-Debug`.

Gradle also uses its normal user-level dependency/distribution cache.

`.build/`, `.signing/` and `_artifacts/` are ignored by Git. Neither previous APKs
nor files outside these output locations are deleted. The original Gradle APK
remains in `app/build/outputs/apk/release/`, or in
`app/build/outputs/apk/debug/` with `-Debug`. The copied APK is selected from the
current Gradle output metadata, so older APKs left by previous versions are not
mistaken for the new build.

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
